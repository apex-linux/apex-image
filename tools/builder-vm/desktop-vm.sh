#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
Desktop VM: try the Apex image the builder VM built, in a window on this host. The
image is installed with the qualification's install code onto a disk laid out like the
laptop minus LUKS (ESP + ext4 /boot + btrfs root), and boots with UEFI, KVM,
virtio-gpu with OpenGL (virgl) and PipeWire sound (playback only by default). The
first boot runs gnome-initial-setup, where you create your user. QEMU runs as your
normal user; nothing needs root on the host.

  desktop-vm.sh install [--replace] [IMAGE]
                         install IMAGE (default localhost/apex:build, the result of
                         builder-vm.sh image) onto a new disk in the builder VM, then
                         copy the disk here. The builder VM is started for this and
                         stopped again if it was not running. --replace discards an
                         existing desktop disk and everything done in it. IMAGE must
                         have passed G2 in the builder VM (see APEX_DESKTOP_UNGATED)
  desktop-vm.sh start    open the VM window (QEMU runs in the background)
  desktop-vm.sh stop     shut the guest down: systemctl poweroff over SSH (it finalizes
                         staged updates), else the ACPI power button; after 180 s QEMU
                         is stopped hard, like pulling the power
  desktop-vm.sh status   running or not, the booted and staged images (from the guest
                         while it runs), disk use
  desktop-vm.sh ssh [CMD...]
                         root shell (or CMD) in the guest: key-only, 127.0.0.1 only
  desktop-vm.sh screenshot [FILE]
                         save the guest screen as PNG (default: a timestamped file in
                         the VM directory) and print its path; needs APEX_DESKTOP_GL=off
  desktop-vm.sh update [IMAGE]
                         send IMAGE (default localhost/apex:build) from the builder VM
                         into the running guest (podman save | podman load) and stage it
                         with bootc switch --transport containers-storage; /var/home and
                         /etc carry over. It refuses a guest that does not run Apex, an
                         image that is not Apex's and one that has not passed G2, prints
                         the booted and the staged digest, and how to roll back
  desktop-vm.sh destroy --yes
                         delete the desktop disk, firmware variables and SSH key
  desktop-vm.sh target   print the VM directory
  desktop-vm.sh running  exit 0 when the VM runs, 1 when not (no output)
  desktop-vm.sh exec CMD...
                         CMD in the guest as root, for scripts that ran `target` first

Every command but help, running and exec first prints the VM it targets. Every command
but running refuses the owner's VM without a terminal on stdin, or in an agent's session
(CLAUDECODE set), unless APEX_DESKTOP_THROWAWAY is set (0 names the owner's VM on
purpose).

In the window (titled "QEMU (Apex desktop)"): Ctrl+Alt+G grabs keyboard and mouse, so
Super and other shortcuts reach the guest; press it again to release. Ctrl+Alt+F
toggles full screen. The close button is disabled, because closing the window would
cut the power; Machine > Quit (Ctrl+Alt+Q) and Machine > Reset still do, so avoid
them. Shut down from GNOME, with Machine > Power Down, or with `desktop-vm.sh stop`.

Environment (defaults in brackets):
  APEX_DESKTOP_DIR       [${XDG_DATA_HOME:-~/.local/share}/apex/desktop] VM files
  APEX_DESKTOP_MEM       [4G]   guest RAM; free pages go back to the host (balloon)
  APEX_DESKTOP_CPUS      [4]    vCPUs
  APEX_DESKTOP_DISK_GB   [64]   virtual disk size at install (qcow2, grows on demand)
  APEX_DESKTOP_SSH_PORT  [2223] host port for the guest's sshd, bound to 127.0.0.1
  APEX_DESKTOP_GL        [on]   off: virtio-vga without OpenGL (software rendering)
  APEX_DESKTOP_AUDIO     [pipewire] pipewire, pa, alsa or none
  APEX_DESKTOP_MIC       [0]    1: also give the guest the host's default microphone
  APEX_DESKTOP_SHARP     [0]    1: render the guest at the window's device pixels on a
                                HiDPI or fractionally scaled host (see "Sharpness")
  APEX_DESKTOP_THROWAWAY [0]    1: refuse the owner's VM directory and SSH port, and
                                every directory that `install` did not mark throwaway;
                                0 set explicitly: a script may use the owner's VM
  APEX_DESKTOP_UNGATED   [0]    1: install or update with an image that has not passed
                                G2 in the builder VM (_build/gates-passed.txt, or a
                                passed _build/g2/*/result.txt)

A running VM is reached on the SSH port it was started with, whatever
APEX_DESKTOP_SSH_PORT says later.

Sharpness: QEMU's GTK window reports its size to the guest in logical pixels. On a
scaled host (this laptop: 166 %, which GTK 3 draws at 2x) the guest image is then
stretched, so text is soft. APEX_DESKTOP_SHARP=1 sets the window's zoom to 1/scale
(QEMU `-display gtk,scale=`, zoom-to-fit off): the guest renders at the resolution of
GTK's 2x window buffer, and QEMU does not stretch it. GNOME still scales the window to
166 %, as it does every GTK 3 app. In this mode the window follows the guest's mode, so
it opens small and shrinks back at every guest reboot: maximize it (the guest follows
within a second) and keep it maximized, then set Settings > Displays > Scale to 200 %
in the guest once. Full screen gives the guest logical pixels again.

The guest's sshd accepts only the key made here for root (password logins stay as the
image ships them), and QEMU forwards it on the host's loopback only. User-mode
networking lets the guest reach the internet, and also every service listening on the
host's 127.0.0.1, at 10.0.2.2.
EOF
}

readonly OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
readonly OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
readonly DEFAULT_IMAGE=localhost/apex:build
readonly QEMU_PROCESS_NAME=apex-desktop
readonly OWNER_VM_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/apex/desktop
readonly DEFAULT_SSH_PORT=2223
# image/Containerfile's label: a local build has no version label to tell it by.
readonly APEX_IMAGE_SOURCE=https://github.com/SekiroKenjii/apex-fedora

VM_DIR=$(realpath -m -- "${APEX_DESKTOP_DIR:-$OWNER_VM_DIR}")
MEM=${APEX_DESKTOP_MEM:-4G}
CPUS=${APEX_DESKTOP_CPUS:-4}
DISK_GB=${APEX_DESKTOP_DISK_GB:-64}
SSH_PORT=${APEX_DESKTOP_SSH_PORT:-$DEFAULT_SSH_PORT}
GL=${APEX_DESKTOP_GL:-on}
AUDIO=${APEX_DESKTOP_AUDIO:-pipewire}
MIC=${APEX_DESKTOP_MIC:-0}
SHARP=${APEX_DESKTOP_SHARP:-0}
THROWAWAY=${APEX_DESKTOP_THROWAWAY:-0}
UNGATED=${APEX_DESKTOP_UNGATED:-0}

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
STARTED_SSH_PORT=$VM_DIR/ssh-port
THROWAWAY_MARKER=$VM_DIR/throwaway
SHELL_DEV_INPUTS=$VM_DIR/shell-dev
# desktop-disk.sh's output for this VM, relative to the builder's home as builder-vm.sh
# fetch wants: installs of different VMs never share it.
REMOTE_OUT_NAME=$(printf '%s' "$VM_DIR" | sha256sum | cut -c1-12)
REMOTE_OUT=apex-fedora/_build/desktop/$REMOTE_OUT_NAME

log() { printf '[desktop-vm] %s\n' "$*" >&2; }
die() { printf '[desktop-vm] error: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local t missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
}

# Every desktop VM's QEMU has one name, so only its -pidfile tells whose it is.
is_vm() {
    local pid=$1 argument previous=
    [[ $(cat "/proc/$pid/comm" 2>/dev/null) == "$QEMU_PROCESS_NAME" ]] || return 1
    while IFS= read -r -d '' argument; do
        if [[ $previous == -pidfile ]]; then
            [[ $(realpath -m -- "$argument") == "$PIDFILE" ]]
            return
        fi
        previous=$argument
    done <"/proc/$pid/cmdline"
    return 1
}

# QEMU removes its pidfile only when it exits cleanly. A stale one is dropped, so its PID,
# which another process may have by now, is never signalled.
running() {
    local pid
    [[ -s $PIDFILE ]] || return 1
    pid=$(<"$PIDFILE")
    if [[ $pid =~ ^[0-9]+$ ]] && is_vm "$pid"; then return 0; fi
    rm -f -- "$PIDFILE"
    return 1
}

# install holds the lock to the end, so no VM can boot the disk it is about to replace.
lock() {
    mkdir -p "$VM_DIR"
    exec 9>"$LOCK"
    flock -n 9 || die "another desktop-vm.sh install, start or update is running"
}

same_dir() { [[ $(realpath -m -- "$1") == "$(realpath -m -- "$2")" ]]; }

is_owner_vm() { same_dir "$VM_DIR" "$OWNER_VM_DIR"; }

port_started_with() {
    local port
    [[ -s $1/ssh-port ]] || return 1
    port=$(<"$1/ssh-port")
    [[ $port =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$port"
}

ssh_port() {
    if running && port_started_with "$VM_DIR"; then return 0; fi
    printf '%s\n' "$SSH_PORT"
}

target_kind() {
    if is_owner_vm; then
        printf "the owner's desktop VM"
    elif [[ -e $THROWAWAY_MARKER ]]; then
        printf 'a throwaway desktop VM'
    else
        printf 'a desktop VM outside the default directory'
    fi
}

announce_target() { log "target: $(target_kind) in $VM_DIR, ssh 127.0.0.1:$(ssh_port)"; }

guard_throwaway() {
    case $THROWAWAY in
        0) return 0 ;;
        1) ;;
        *) die "APEX_DESKTOP_THROWAWAY must be 0 or 1" ;;
    esac
    is_owner_vm &&
        die "APEX_DESKTOP_THROWAWAY=1 refuses the owner's desktop VM ($VM_DIR); set APEX_DESKTOP_DIR to a throwaway directory"
    local port owner_port
    port=$(ssh_port)
    owner_port=$(port_started_with "$OWNER_VM_DIR" || printf '%s' "$DEFAULT_SSH_PORT")
    if [[ $port == "$DEFAULT_SSH_PORT" || $port == "$owner_port" ]]; then
        die "APEX_DESKTOP_THROWAWAY=1 refuses ssh port $port, which the owner's desktop VM uses; set APEX_DESKTOP_SSH_PORT"
    fi
    [[ -e $THROWAWAY_MARKER ]] && return 0
    [[ $1 == install ]] ||
        die "$VM_DIR is not a throwaway desktop VM (no $THROWAWAY_MARKER); create one with: APEX_DESKTOP_THROWAWAY=1 $0 install"
    [[ ! -e $DISK ]] ||
        die "$DISK exists, but $VM_DIR is not marked throwaway; refusing to take it over"
    mkdir -p "$VM_DIR"
    : >"$THROWAWAY_MARKER"
}

in_agent_session() { [[ -n ${CLAUDECODE:-} ]]; }

# A script or an agent that forgot its throwaway settings must not reach the owner's VM.
guard_owner_vm() {
    is_owner_vm || return 0
    [[ -n ${APEX_DESKTOP_THROWAWAY+set} ]] && return 0
    local why="stdin is not a terminal, so this may be a script"
    if in_agent_session; then
        why="CLAUDECODE is set, so an agent runs this"
    elif [[ -t 0 ]]; then
        return 0
    fi
    die "$why: set APEX_DESKTOP_THROWAWAY=0 to use the owner's desktop VM ($VM_DIR), or APEX_DESKTOP_THROWAWAY=1 and a throwaway APEX_DESKTOP_DIR"
}

remote_command() { printf '%q ' "$@"; }

monitor() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MONITOR"; }

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

ssh_command=()
init_ssh_command() {
    ssh_command=(ssh -i "$KEY" -p "$(ssh_port)" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o ServerAliveInterval=30
        -o LogLevel=ERROR root@127.0.0.1)
}

vm_ssh() {
    init_ssh_command
    "${ssh_command[@]}" "$@"
}

# exec, so a caller that runs this in the background stops the connection with one signal.
exec_vm_ssh() {
    init_ssh_command
    exec "${ssh_command[@]}" "$@"
}

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

    local image_info
    image_info=$(builder_image_id_and_size "$image")
    require_gated_image "$image" "${image_info%% *}"
    log "installing $image in the builder VM (about 5 minutes)"
    "$BUILDER" run env "DESKTOP_DISK_GB=$DISK_GB" "DESKTOP_OUT=$REMOTE_OUT_NAME" \
        tools/builder-vm/desktop-disk.sh "$image" "$(cat "$KEY.pub")"

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
    # The close button would stop QEMU like a power cut.
    display+=,window-close=off
    case $SHARP in
        0) ;;
        1)
            local gs zoom
            gs=$(gtk_scale)
            # At zoom 1/gs a window W wide asks the guest for W*gs pixels, drawn unscaled
            # (ui/gtk.c gd_resize_event). Literals: printf would follow LC_NUMERIC (0,5).
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
    # Only hda-micro lets the guest record the room, from the host's default source.
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

    local name="Apex desktop"
    [[ -e $THROWAWAY_MARKER ]] && name="Apex desktop (throwaway)"
    # shellcheck disable=SC2054 # QEMU option values are comma-separated key=value lists
    local args=(-name "$name,process=$QEMU_PROCESS_NAME"
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
    printf '%s\n' "$SSH_PORT" >"$STARTED_SSH_PORT"
    log "started (pid $(cat "$PIDFILE")); the window is titled 'QEMU ($name)'"
    log "first boot: gnome-initial-setup creates your user; Flathub apps install in the background"
}

wait_exit() {
    local pid=$1 seconds=$2
    local deadline=$((SECONDS + seconds))
    while is_vm "$pid"; do
        ((SECONDS < deadline)) || return 1
        sleep 2
    done
}

stop_vm() {
    running || { log "not running"; rm -f "$PIDFILE"; return 0; }
    local pid
    pid=$(cat "$PIDFILE")
    # poweroff lets ostree finalize a staged update. The ACPI button powers the VM off
    # at once: in a VM gnome-settings-daemon leaves the power key to logind.
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

is_local_image() { [[ $1 =~ ^localhost/[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]]; }

guest_status() { vm_ssh 'bootc status --format=json --format-version=1'; }

require_apex_guest() {
    local variant
    variant=$(vm_ssh 'sed -n "s/^VARIANT_ID=//p" /usr/lib/os-release') ||
        die "cannot read the guest's /usr/lib/os-release over ssh"
    variant=${variant//[\"\']/}
    [[ $variant == apex ]] ||
        die "the desktop VM does not run Apex (VARIANT_ID='$variant' in /usr/lib/os-release); update only switches an Apex desktop VM"
}

builder_image_id_and_size() {
    local fields id size bootc source
    fields=$("$BUILDER" ssh "$(remote_command sudo podman image inspect --format \
        '{{.Id}}|{{.Size}}|{{index .Labels "containers.bootc"}}|{{index .Labels "org.opencontainers.image.source"}}' "$1")") ||
        die "$1 is not in the builder VM's container storage (build it with: just vm-image)"
    IFS='|' read -r id size bootc source <<<"$fields"
    [[ $bootc == 1 && $source == "$APEX_IMAGE_SOURCE" ]] ||
        die "$1 in the builder VM is not the Apex image (containers.bootc=$bootc, org.opencontainers.image.source=$source)"
    [[ $id =~ ^[0-9a-f]{64}$ && $size =~ ^[0-9]+$ ]] || die "podman describes $1 as '$fields'"
    printf '%s %s\n' "$id" "$size"
}

# shellcheck disable=SC2016 # bash in the builder VM expands it
readonly GATE_RECORDS_SCRIPT='
cd apex-fedora/_build 2>/dev/null || exit 1
if grep -qsx "image-id $1" gates-passed.txt; then
    echo "G1 and G2, and G4 $(sed -n "s/^g4 //p" gates-passed.txt) (_build/gates-passed.txt)"
    exit 0
fi
for result in g2/2*Z/result.txt; do
    if grep -qsx "image-id $1" "$result" && grep -qsx "status passed" "$result"; then
        echo "G2 (_build/${result%/result.txt})"
        exit 0
    fi
done
exit 1
'

gates_passed_by() {
    local id=$1
    "$BUILDER" ssh "$(remote_command bash -c "$GATE_RECORDS_SCRIPT" _ "$id")"
}

require_gated_image() {
    local image=$1 id=$2 gates
    case $UNGATED in
        0 | 1) ;;
        *) die "APEX_DESKTOP_UNGATED must be 0 or 1" ;;
    esac
    if gates=$(gates_passed_by "$id"); then
        log "$image (sha256:$id) passed $gates"
    elif ((UNGATED)); then
        log "warning: $image (sha256:$id) has passed no gate; APEX_DESKTOP_UNGATED=1 takes it anyway"
    else
        die "$image (sha256:$id) has passed no G2 in the builder VM (just vm-image, or just vm-g2); APEX_DESKTOP_UNGATED=1 takes it anyway"
    fi
}

guest_image_id() { vm_ssh "$(remote_command podman image inspect --format '{{.Id}}' "$1")" 2>/dev/null || true; }

just_command_for_this_vm() {
    local prefix=()
    is_owner_vm || prefix+=("APEX_DESKTOP_DIR=$(printf '%q' "$VM_DIR")")
    [[ $THROWAWAY == 1 ]] && prefix+=(APEX_DESKTOP_THROWAWAY=1)
    printf '%s\n' "${prefix[*]:+${prefix[*]} }just $*"
}

# Install's fields stay: the guest boots the staged image only after a reboot, and a
# rollback leaves it again.
record_staged() {
    local info=(--arg image "$1" --arg digest "$2" --arg version "$3")
    if [[ -f $INFO ]]; then
        jq "${info[@]}" '.staged = {image: $image, digest: $digest, version: $version}' "$INFO" >"$INFO.part"
    else
        jq -n "${info[@]}" '{staged: {image: $image, digest: $digest, version: $version}}' >"$INFO.part"
    fi
    mv -f -- "$INFO.part" "$INFO"
}

update() {
    local image=$DEFAULT_IMAGE
    case $# in
        0) ;;
        1) image=$1 ;;
        *) die "usage: $0 update [IMAGE]" ;;
    esac
    is_local_image "$image" || die "IMAGE must be a local image reference localhost/NAME[:TAG], got '$image'"
    require_tools ssh jq flock
    lock
    running || die "the desktop VM is not running ($0 start); update stages the image in the running guest"
    require_apex_guest

    local before booted_ref booted_digest booted_version
    before=$(guest_status) || die "bootc status failed in the guest"
    booted_ref=$(jq -r '.status.booted.image.image // empty | "\(.transport):\(.image)"' <<<"$before")
    booted_digest=$(jq -r '.status.booted.image.imageDigest // empty' <<<"$before")
    booted_version=$(jq -r '.status.booted.image.version // "unversioned"' <<<"$before")
    [[ -n $booted_digest ]] || die "bootc reports no booted image in the guest"
    log "booted: $booted_ref $booted_digest ($booted_version)"

    if ! "$BUILDER" running; then
        log "starting the builder VM for the update; it stops again afterwards"
        trap '"$BUILDER" stop' EXIT
        "$BUILDER" start
    fi
    local image_info id size
    image_info=$(builder_image_id_and_size "$image")
    read -r id size <<<"$image_info"
    require_gated_image "$image" "$id"
    log "new: $image, image sha256:$id"

    local avail
    avail=$(vm_ssh 'df --output=avail -B1 /var | tail -n 1') || die "cannot read the guest's free space"
    avail=${avail//[[:space:]]/}
    [[ $avail =~ ^[0-9]+$ ]] || die "cannot read the guest's free space: '$avail'"
    # podman load keeps the whole archive in /var/tmp while it stores the image.
    ((avail > 2 * size + 2 * 1024 ** 3)) ||
        die "the guest has $((avail / 1024 ** 3)) GiB free in /var; loading a $((size / 1024 ** 3)) GiB image needs twice that plus 2 GiB"

    local previous_id
    previous_id=$(guest_image_id "$image")
    log "sending $image ($((size / 1024 ** 2)) MiB) from the builder VM: podman save | podman load"
    "$BUILDER" ssh "$(remote_command sudo podman save --format oci-archive "$image")" |
        vm_ssh 'podman load --quiet' >&2 ||
        die "podman save | podman load failed; nothing was staged"
    vm_ssh "$(remote_command podman tag "$id" "$image")" || die "podman tag failed in the guest"
    [[ $(guest_image_id "$image") == "$id" ]] || die "the guest's $image is not sha256:$id after the load"

    local stage
    if [[ $(jq -r '.spec.image // empty | "\(.transport):\(.image)"' <<<"$before") == "containers-storage:$image" ]]; then
        stage=(bootc upgrade)
    else
        stage=(bootc switch --transport containers-storage "$image")
    fi
    log "staging: ${stage[*]}"
    vm_ssh "$(remote_command "${stage[@]}")" >&2 || die "${stage[*]} failed in the guest; the booted system is unchanged"

    local after staged_digest staged_version
    after=$(guest_status) || die "bootc status failed in the guest after staging"
    staged_digest=$(jq -r '.status.staged.image.imageDigest // empty' <<<"$after")
    staged_version=$(jq -r '.status.staged.image.version // "unversioned"' <<<"$after")
    if [[ -z $staged_digest ]]; then
        log "nothing staged: bootc found no change from the booted $booted_digest"
        return 0
    fi
    if [[ -n $previous_id && $previous_id != "$id" ]]; then
        vm_ssh "$(remote_command podman rmi "$previous_id")" >/dev/null 2>&1 || true
    fi
    record_staged "$image" "$staged_digest" "$staged_version"

    log "old digest (booted): $booted_digest"
    log "new digest (staged): $staged_digest"
    log "the guest keeps running the old image until it restarts; /var/home and /etc carry over (bootc keeps /var and merges /etc)"
    log "boot it:   $(just_command_for_this_vm desktop-ssh "'systemctl reboot'")   (or restart from GNOME)"
    log "roll back: $(just_command_for_this_vm desktop-ssh "'bootc rollback && systemctl reboot'")   after that boot: it boots $booted_digest again"
}

status() {
    local guest
    if running; then
        log "running (pid $(cat "$PIDFILE")), ssh: $0 ssh"
        if guest=$(guest_status 2>/dev/null); then
            log "booted: $(jq -r '.status.booted.image // {} | "\(.image.image // "?") \(.version // "unversioned") \(.imageDigest // "?")"' <<<"$guest")"
            log "staged: $(jq -r '.status.staged.image // null | if . then "\(.image.image) \(.version // "unversioned") \(.imageDigest)" else "nothing" end' <<<"$guest")"
        else
            log "ssh not answering yet"
        fi
    else
        log "stopped"
        [[ -f $INFO ]] && log "installed: $(jq -r '"\(.image // "?") \(.version // "?") \(.digest // "?")"' "$INFO")"
        [[ -f $INFO ]] && jq -e .staged "$INFO" >/dev/null &&
            log "staged by the last update (boots after a reboot, unless rolled back since): $(jq -r '.staged | "\(.image) \(.version) \(.digest)"' "$INFO")"
    fi
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
        "$SERIAL" "$LOCK" "$KNOWN_HOSTS" "$KEY" "$KEY.pub" "$STARTED_SSH_PORT"
    rm -rf -- "$SHELL_DEV_INPUTS"
    log "deleted the desktop VM (screenshots stay in $VM_DIR/screenshots)"
}

main() {
    [[ $(id -u) -ne 0 ]] || die "run as your normal user; the VM needs no root on the host"
    local cmd=${1:-help}
    shift || true
    case $cmd in
        help | -h | --help) usage; return ;;
        install | start | stop | status | ssh | screenshot | update | destroy | target | running | exec) ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
    guard_throwaway "$cmd"
    case $cmd in
        running) ;;
        *) guard_owner_vm ;;
    esac
    case $cmd in
        running | exec) ;;
        *) announce_target ;;
    esac
    case $cmd in
        install) install "$@" ;;
        start) start ;;
        stop) stop_vm ;;
        status) status ;;
        ssh) running || die "the desktop VM is not running ($0 start)"; vm_ssh "$@" ;;
        screenshot) screenshot "$@" ;;
        update) update "$@" ;;
        destroy) destroy "$@" ;;
        target) printf '%s\n' "$VM_DIR" ;;
        running) running ;;
        exec)
            (($#)) || die "usage: $0 exec CMD..."
            running || die "the desktop VM is not running ($0 start)"
            exec_vm_ssh "$@" ;;
    esac
}

main "$@"
