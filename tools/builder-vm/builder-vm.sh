#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
Local Fedora 45 builder VM (ADR 0013): user-mode QEMU with KVM, no root on the host,
which runs Ubuntu or Fedora. The VM runs rootful podman, build-rootfs, rpmbuild and
(with nested KVM) the qualification boots. The repository is copied in with rsync; the
VM never mounts host directories.

  builder-vm.sh create        download and verify Fedora Cloud 45, create the disk,
                              first boot with cloud-init, provision the tools
  builder-vm.sh start|stop    boot in the background / clean ACPI shutdown
  builder-vm.sh status        running or not, uptime, disk and memory use
  builder-vm.sh ssh [CMD...]  a shell (or CMD) in the VM as user "builder"
  builder-vm.sh running       exit 0 when the VM runs, 1 when not (no output)
  builder-vm.sh sync          rsync the repository to ~/apex-image in the VM
  builder-vm.sh fetch REMOTE LOCAL
                              copy the file REMOTE (relative to the builder user's home
                              in the VM) to LOCAL on the host; resumes a partial copy
  builder-vm.sh run CMD...    sync, then run CMD in ~/apex-image in the VM
  builder-vm.sh image [--image-only] [--kernel fedora]
                              sync, then build the RPM inputs and the image in the VM
                              (--image-only reuses the RPMs of the previous run;
                              --kernel fedora is the break-glass image, never promoted)
  builder-vm.sh provision     re-run the guest provisioning (idempotent)
  builder-vm.sh ci-install PUBKEY
                              install ci-build, the self-hosted runner's entry point,
                              and bind the ssh public key in the file PUBKEY to it with
                              restrict,command= (tools/runner/README.md)
  builder-vm.sh console       follow the serial console log
  builder-vm.sh destroy --yes delete the VM disk, firmware vars and keys (keeps the
                              verified base image cache)

Environment (defaults in brackets):
  APEX_VM_DIR       [${XDG_DATA_HOME:-~/.local/share}/apex/builder] VM files
  APEX_VM_MEM       [6G]    guest RAM; a free-page-reporting balloon returns unused
                            pages to the host, and the guest has zram swap
  APEX_VM_CPUS      [8]     vCPUs (the host has 12 threads)
  APEX_VM_DISK      [120G]  virtual disk size (qcow2, grows on demand)
  APEX_VM_SSH_PORT  [2222]  host port forwarded to the guest's sshd, bound to 127.0.0.1

Trust: the base image is Fedora-Cloud-Base-Generic 45 Beta. Its CHECKSUM file is
verified with gpgv against the Fedora 45 primary key, whose fingerprint is pinned
below (cross-checked on 2026-09-24 between https://fedoraproject.org/fedora.gpg and
src.fedoraproject.org/rpms/fedora-repos f45), then the image's SHA-256 is checked.
EOF
}

readonly FEDORA_KEY_FPR=4F50A6114CD5C6976A7F1179655A4B02F577861E
readonly FEDORA_KEY_URL=https://src.fedoraproject.org/rpms/fedora-repos/raw/f45/f/RPM-GPG-KEY-fedora-45-primary
readonly IMAGE_BASE_URL=https://download.fedoraproject.org/pub/fedora/linux/releases/test/45_Beta/Cloud/x86_64/images
readonly IMAGE_NAME=Fedora-Cloud-Base-Generic-45_Beta-1.3.x86_64.qcow2
readonly CHECKSUM_NAME=Fedora-Cloud-images-45_Beta-1.3-x86_64-CHECKSUM
readonly QEMU_PROCESS_NAME=apex-builder
# The guest's Linux 7.2 panicked in KVM's async page fault path during G4 (2026-09-29):
# "Host injected async #PF in interrupt disabled region".
readonly QEMU_CPU=host,kvm-asyncpf=off,kvm-asyncpf-int=off
readonly HOST_LOOPBACK_FROM_GUEST=10.0.2.2
readonly CI_BUILD=/usr/local/libexec/apex/ci-build
readonly CI_KEY_COMMENT=apex-ci
# Taken by ci-build too, so that a CI build and a sync or build from this host never overlap.
# shellcheck disable=SC2088 # expanded by the guest's shell
readonly GUEST_BUILD_LOCK='~/.apex-build.lock'

VM_DIR=${APEX_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/apex/builder}
MEM=${APEX_VM_MEM:-6G}
CPUS=${APEX_VM_CPUS:-8}
DISK_SIZE=${APEX_VM_DISK:-120G}
SSH_PORT=${APEX_VM_SSH_PORT:-2222}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
readonly HERE REPO
# shellcheck source=SCRIPTDIR/firmware.sh
. "$HERE/firmware.sh"

BASE_DIR=$VM_DIR/base
DISK=$VM_DIR/disk.qcow2
VARS=$VM_DIR/OVMF_VARS.fd
KEY=$VM_DIR/ssh/id_ed25519
KNOWN_HOSTS=$VM_DIR/ssh/known_hosts
PIDFILE=$VM_DIR/qemu.pid
MONITOR=$VM_DIR/monitor.sock
SERIAL=$VM_DIR/serial.log
SEED_DIR=$VM_DIR/seed

log() { printf '[builder-vm] %s\n' "$*" >&2; }
die() { printf '[builder-vm] error: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local t missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
}

is_vm() { [[ $(cat "/proc/$1/comm" 2>/dev/null) == "$QEMU_PROCESS_NAME" ]]; }

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

ssh_opts=()
init_ssh_opts() {
    ssh_opts=(-i "$KEY" -p "$SSH_PORT"
        -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5
        -o ServerAliveInterval=30 -o LogLevel=ERROR)
}

vm_ssh() {
    init_ssh_opts
    # shellcheck disable=SC2029 # the arguments are a remote command, expanded remotely on purpose
    ssh "${ssh_opts[@]}" builder@127.0.0.1 "$@"
}

fetch() {
    local url=$1 dest=$2
    curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - -o "$dest.part" "$url"
    mv -f "$dest.part" "$dest"
}

verify_base() {
    local tmp keyring fpr expected actual
    tmp=$(mktemp -d)
    # A RETURN trap outlives the function in bash; clear it when it runs.
    trap 'rm -rf "$tmp"; trap - RETURN' RETURN
    fetch "$FEDORA_KEY_URL" "$tmp/key.asc"
    fpr=$(gpg --show-keys --with-colons "$tmp/key.asc" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
    [[ $fpr == "$FEDORA_KEY_FPR" ]] || die "Fedora 45 key fingerprint is $fpr, expected $FEDORA_KEY_FPR"
    keyring=$tmp/fedora45.gpg
    gpg --dearmor <"$tmp/key.asc" >"$keyring"
    gpgv --keyring "$keyring" "$BASE_DIR/$CHECKSUM_NAME" 2>"$tmp/gpgv.log" \
        || { cat "$tmp/gpgv.log" >&2; die "CHECKSUM signature does not verify with the Fedora 45 key"; }
    expected=$(sed -n "s/^SHA256 ($IMAGE_NAME) = \([0-9a-f]\{64\}\)$/\1/p" "$BASE_DIR/$CHECKSUM_NAME")
    [[ -n $expected ]] || die "no SHA256 line for $IMAGE_NAME in $CHECKSUM_NAME"
    actual=$(sha256sum "$BASE_DIR/$IMAGE_NAME" | awk '{print $1}')
    [[ $actual == "$expected" ]] || die "SHA-256 mismatch for $IMAGE_NAME: $actual, expected $expected"
    log "verified $IMAGE_NAME (signed CHECKSUM, sha256 $actual)"
}

ensure_base() {
    mkdir -p "$BASE_DIR"
    [[ -s $BASE_DIR/$CHECKSUM_NAME ]] || fetch "$IMAGE_BASE_URL/$CHECKSUM_NAME" "$BASE_DIR/$CHECKSUM_NAME"
    [[ -s $BASE_DIR/$IMAGE_NAME ]] || { log "downloading $IMAGE_NAME (about 630 MB)"; fetch "$IMAGE_BASE_URL/$IMAGE_NAME" "$BASE_DIR/$IMAGE_NAME"; }
    verify_base
    chmod a-w "$BASE_DIR/$IMAGE_NAME"
}

launch() {
    local seed_url=${1:-} args
    running && die "the VM is already running (pid $(cat "$PIDFILE"))"
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable by $(id -un)"
    find_ovmf
    check_vars "$VARS"
    # shellcheck disable=SC2054 # QEMU option values are comma-separated key=value lists
    args=(-name "apex-builder,process=$QEMU_PROCESS_NAME"
        -machine q35,accel=kvm -cpu "$QEMU_CPU" -smp "$CPUS" -m "$MEM"
        -drive "if=pflash,format=$OVMF_FORMAT,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=$OVMF_FORMAT,file=$VARS"
        -drive "file=$DISK,if=virtio,format=qcow2,discard=unmap,detect-zeroes=unmap,cache=writeback"
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
        -device virtio-net-pci,netdev=n0
        -device virtio-rng-pci
        -device virtio-balloon-pci,free-page-reporting=on
        -display none -serial "file:$SERIAL"
        -monitor "unix:$MONITOR,server=on,wait=off"
        -pidfile "$PIDFILE" -daemonize)
    [[ -n $seed_url ]] && args+=(-smbios "type=1,serial=ds=nocloud;s=$seed_url")
    : >"$SERIAL"
    qemu-system-x86_64 "${args[@]}"
    log "started (pid $(cat "$PIDFILE")), ssh on 127.0.0.1:$SSH_PORT, console log $SERIAL"
}

wait_for_ssh() {
    local timeout_seconds=$1
    local deadline=$((SECONDS + timeout_seconds))
    until vm_ssh true 2>/dev/null; do
        running || die "QEMU exited during boot; see $SERIAL"
        ((SECONDS < deadline)) || die "no ssh after $timeout_seconds s; see $SERIAL"
        sleep 3
    done
}

stop_vm() {
    running || { log "not running"; rm -f "$PIDFILE"; return 0; }
    local pid deadline
    pid=$(cat "$PIDFILE")
    log "ACPI shutdown (pid $pid)"
    printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$MONITOR" >/dev/null 2>&1 || true
    deadline=$((SECONDS + 120))
    while is_vm "$pid"; do
        if ((SECONDS >= deadline)); then
            log "no shutdown after 120 s; stopping QEMU"
            printf 'quit\n' | socat - "UNIX-CONNECT:$MONITOR" >/dev/null 2>&1 || { is_vm "$pid" && kill "$pid"; } || true
            break
        fi
        sleep 2
    done
    rm -f "$PIDFILE"
}

write_seed() {
    local pub
    pub=$(cat "$KEY.pub")
    mkdir -p "$SEED_DIR"
    printf 'instance-id: apex-builder-%s\nlocal-hostname: apex-builder\n' "$(date +%s)" >"$SEED_DIR/meta-data"
    cat >"$SEED_DIR/user-data" <<EOF
#cloud-config
users:
  - name: builder
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $pub
ssh_pwauth: false
disable_root: true
growpart:
  mode: auto
  devices: ["/"]
resize_rootfs: true
EOF
    : >"$SEED_DIR/vendor-data"
}

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

provision() {
    log "provisioning the guest (tools for image, RPM and qualification builds)"
    vm_ssh 'bash -s' <"$HERE/provision.sh"
    local version sum
    version=$(sed -n 's/^COSIGN_VERSION=//p' "$HERE/cosign.env")
    sum=$(sed -n 's/^COSIGN_SHA256=//p' "$HERE/cosign.env")
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $sum =~ ^[0-9a-f]{64}$ ]] ||
        die "$HERE/cosign.env needs COSIGN_VERSION=vX.Y.Z and COSIGN_SHA256=<64 hex>"
    vm_ssh "bash -s -- $version $sum" <"$HERE/install-cosign.sh"
}

create() {
    require_tools qemu-system-x86_64 qemu-img curl gpg gpgv sha256sum ssh ssh-keygen rsync socat python3
    [[ -e $DISK ]] && die "$DISK already exists (builder-vm.sh destroy --yes first)"
    find_ovmf
    mkdir -p "$VM_DIR/ssh"
    chmod 0700 "$VM_DIR" "$VM_DIR/ssh"
    ensure_base
    [[ -s $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C apex-builder -f "$KEY"
    rm -f "$KNOWN_HOSTS"
    cp "$OVMF_VARS_TEMPLATE" "$VARS"
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_DIR/$IMAGE_NAME" "$DISK" "$DISK_SIZE"
    write_seed

    local port http_pid
    port=$(free_port)
    python3 -m http.server --bind 127.0.0.1 --directory "$SEED_DIR" "$port" >"$VM_DIR/seed-http.log" 2>&1 &
    http_pid=$!
    trap 'kill "$http_pid" 2>/dev/null || true' EXIT
    launch "http://$HOST_LOOPBACK_FROM_GUEST:$port/"
    log "first boot: waiting for cloud-init and ssh (a few minutes)"
    wait_for_ssh 600
    vm_ssh 'sudo cloud-init status --wait >/dev/null; cloud-init status --long | sed -n 1,3p' >&2 || true
    kill "$http_pid" 2>/dev/null || true
    trap - EXIT
    provision
    log "ready. Try: $0 ssh   or   $0 image"
}

status() {
    if running; then
        log "running (pid $(cat "$PIDFILE")), ssh: $0 ssh"
        vm_ssh 'uptime; df -h / | tail -1; free -h | sed -n 2,3p' 2>/dev/null || log "ssh not answering yet"
    else
        log "stopped"
    fi
    [[ -e $DISK ]] && log "disk: $(du -h "$DISK" | cut -f1) used on the host, $DISK"
}

require_build_lock_free() {
    vm_ssh "flock -n $GUEST_BUILD_LOCK true" </dev/null ||
        die "a CI build (ci-build) holds the builder VM; wait for it, or see: $0 ssh 'pgrep -af build-image'"
}

sync_repo() {
    running || die "the VM is not running ($0 start)"
    require_build_lock_free
    init_ssh_opts
    local rsh="ssh ${ssh_opts[*]}"
    rsync -a --delete --info=stats1 --rsync-path="flock -n $GUEST_BUILD_LOCK rsync" \
        --exclude=/target/ --exclude=/_build/ --exclude=/rpms/ \
        -e "$rsh" "$REPO/" builder@127.0.0.1:apex-image/
}

fetch_file() {
    local remote=$1 destination=$2
    running || die "the VM is not running ($0 start)"
    [[ $remote != /* && $remote != *..* ]] || die "fetch: REMOTE must be relative to the builder's home, got '$remote'"
    init_ssh_opts
    local rsh="ssh ${ssh_opts[*]}"
    rsync --partial --info=progress2 -e "$rsh" "builder@127.0.0.1:$remote" "$destination"
}

run_in_repo() {
    sync_repo
    local cmd
    printf -v cmd '%q ' "$@"
    vm_ssh -t "cd ~/apex-image && flock -n $GUEST_BUILD_LOCK $cmd"
}

image() {
    sync_repo
    # Run by path, not fed through `bash -s`: G4's ssh (qualify.sh, no -n) would read the rest of the script.
    vm_ssh "flock -n $GUEST_BUILD_LOCK bash ~/apex-image/tools/builder-vm/build-image.sh $*" </dev/null
}

ci_install() {
    local pubkey_file=$1 type blob line
    [[ -r $pubkey_file ]] || die "ci-install: cannot read $pubkey_file"
    read -r type blob _ <"$pubkey_file" || true
    [[ $type == ssh-ed25519 && $blob =~ ^[A-Za-z0-9+/]+=*$ && $(wc -l <"$pubkey_file") -le 1 ]] ||
        die "ci-install: $pubkey_file is not one ssh-ed25519 public key"
    ssh-keygen -l -f "$pubkey_file" >/dev/null || die "ci-install: ssh-keygen does not read $pubkey_file"
    line="restrict,command=\"$CI_BUILD\" $type $blob $CI_KEY_COMMENT"
    vm_ssh "sudo install -d -m 0755 ${CI_BUILD%/*} && sudo tee $CI_BUILD >/dev/null && sudo chmod 0755 $CI_BUILD" \
        <"$HERE/ci-build.sh"
    vm_ssh "bash -s -- $(printf '%q ' "$line" "$CI_KEY_COMMENT")" <<'EOF'
set -euo pipefail
keys=$HOME/.ssh/authorized_keys
umask 077
mkdir -p "$HOME/.ssh"
touch "$keys"
grep -v " $2\$" "$keys" >"$keys.new" || true
printf '%s\n' "$1" >>"$keys.new"
mv -f "$keys.new" "$keys"
mkdir -p "$HOME/.config/apex"
[[ -e $HOME/.config/apex/ci.env ]] || printf 'APEX_CI_REMOTE=https://github.com/apex-linux/apex-image.git\n' >"$HOME/.config/apex/ci.env"
EOF
    log "installed $CI_BUILD; the key $(ssh-keygen -l -f "$pubkey_file" | cut -d' ' -f2) may run only ci-build <sha>"
    log "main is fetched from $(vm_ssh 'sed -n "s/^APEX_CI_REMOTE=//p" ~/.config/apex/ci.env' </dev/null) (~/.config/apex/ci.env in the VM)"
}

destroy() {
    [[ ${1:-} == --yes ]] || die "destroy deletes $DISK, $VARS and the VM ssh key; run: $0 destroy --yes"
    running && stop_vm
    rm -f -- "$DISK" "$VARS" "$SERIAL" "$VM_DIR/seed-http.log" "$KNOWN_HOSTS" "$KEY" "$KEY.pub"
    rm -rf -- "$SEED_DIR"
    log "deleted the VM (the verified base image stays in $BASE_DIR)"
}

main() {
    [[ $(id -u) -ne 0 ]] || die "run as your normal user; the VM needs no root on the host"
    local cmd=${1:-help}
    shift || true
    case $cmd in
        create) create ;;
        start) [[ -e $DISK ]] || die "no VM yet ($0 create)"; launch; wait_for_ssh 300; log "ssh is up" ;;
        stop) stop_vm ;;
        status) status ;;
        ssh) running || die "the VM is not running ($0 start)"; vm_ssh "$@" ;;
        running) running ;;
        sync) sync_repo ;;
        fetch) (($# == 2)) || die "usage: $0 fetch REMOTE LOCAL"; fetch_file "$1" "$2" ;;
        run) (($#)) || die "usage: $0 run CMD..."; run_in_repo "$@" ;;
        image)
            running || die "the VM is not running ($0 start)"
            case "$*" in
                "" | --image-only | "--kernel fedora" | "--image-only --kernel fedora") ;;
                *) die "usage: $0 image [--image-only] [--kernel fedora]" ;;
            esac
            image "$@" ;;
        provision) running || die "the VM is not running ($0 start)"; provision ;;
        ci-install)
            running || die "the VM is not running ($0 start)"
            (($# == 1)) || die "usage: $0 ci-install PUBKEY"
            ci_install "$1" ;;
        console) exec tail -f "$SERIAL" ;;
        destroy) destroy "$@" ;;
        help | -h | --help) usage ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
}

main "$@"
