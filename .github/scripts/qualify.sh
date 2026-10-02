#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

Qualify an Apex image in a KVM guest with OVMF: a real `bootc install`, GRUB, the Apex
boot counter and boot assessment, signature enforcement and the upgrade path, all on
the digest that will be published.

  qualify.sh host-setup              for a CI runner, if one is ever used: /dev/kvm
                                     access, QEMU, OVMF
  qualify.sh fresh CANDIDATE         install CANDIDATE, boot, assert, negative
                                     signature tests, reboot with a download-only stage
  qualify.sh upgrade FROM CANDIDATE  install FROM (e.g. the current stable), stage
                                     CANDIDATE by digest, apply it with FROM's apexctl
                                     (arms the boot counter), reboot, assert green and
                                     confirmed
  qualify.sh red FROM CANDIDATE      the counted rollback: install FROM, stage
                                     CANDIDATE, write CANDIDATE's digest to the hook
                                     /var/lib/apex/force-red, apply, then boot without
                                     ever logging in: CANDIDATE must fail its assessment
                                     and reboot itself 3 times, GRUB must fall back to
                                     FROM, and FROM must roll back (bootc rollback),
                                     denylist CANDIDATE and leave grubenv disarmed
  qualify.sh all CANDIDATE           fresh, then upgrade and red from apex:45 when it
                                     exists and differs from CANDIDATE
  qualify.sh local IMAGE             G4 for an unpublished image in local container
                                     storage (localhost/NAME:TAG, e.g. image.sh's
                                     localhost/apex:build), without the signature tests
                                     (a local image carries no signature): install, boot
                                     green on composefs; the counted rollback of a newer
                                     image derived from it in the guest; GDM's greeter;
                                     the login of a user made only in the guest through
                                     the greeter (its password typed over QEMU's QMP),
                                     with the Apex layer on and its crash guard armed;
                                     lock, and unlock by the password typed into the
                                     unlock dialog and by loginctl, with no JS ERROR;
                                     a login with APEX_SHELL_TEST_FAULT=abort-after-enable
                                     that trips the crash guard, then a login in safe
                                     mode; bootloader-update.service after every green
                                     boot and on no red one. Only a pass with no SKIP or
                                     WARN row records the image's G4 key, the time and
                                     the image ID
  qualify.sh g4-key IMAGE            print the G4 key of a local image: the NEVRAs of
                                     gdm, gnome-shell, mutter, gjs, gnome-session,
                                     accountsservice, pam, systemd, the kernel, shim,
                                     GRUB and bootupd, the digest of every file of apex
                                     and apex-desktop, of every /usr file of the image
                                     overlay (image/system_files) and of the kargs
  qualify.sh g4-due KEY              exit 0 when G4 is due for the image whose key
                                     (g4-key's output) is in the file KEY: it differs
                                     from the last local pass, that pass is more than 7
                                     days old, or none is recorded; exit 3 when it is not
                                     due, after printing the pass's passed-at and
                                     image-id lines on stdout

CANDIDATE and FROM are REPO@sha256:... references (a bare sha256:... means
ghcr.io/sekirokenjii/apex-testing@sha256:...). It needs nested KVM, and sudo for
podman, losetup and mount. `red` works with any two different Apex images whose updater
arms the counter, e.g. `qualify.sh red sha256:<older> sha256:<newer>`.

Environment (all optional):
  QUALIFY_OUT           work directory (default _build/qualify); fixtures/ and logs/
                        in it are the artifacts worth keeping
  QUALIFY_LAYOUT        separate-boot (default): ESP + ext4 /boot + btrfs root, the
                        laptop's layout, installed with `bootc install to-filesystem`;
                        to-disk: `bootc install to-disk --via-loopback --filesystem btrfs`
                        (`red` is skipped there: GRUB cannot count on a btrfs /boot)
  QUALIFY_DISK_GB (40)  QUALIFY_MEM (6G)  QUALIFY_SMP (4)  QUALIFY_SSH_PORT (2222)
  QUALIFY_BOOT_TIMEOUT  seconds to wait for SSH after a boot (default 900)
  QUALIFY_ATTEMPT_TIMEOUT  seconds an armed, failing boot may take until it has
                        rebooted itself (default QUALIFY_BOOT_TIMEOUT + 300)
  QUALIFY_POLL          seconds between checks while waiting for QEMU (default 5)
  QUALIFY_LOGIN_TIMEOUT seconds to wait for GDM's greeter, for the login through it, and
                        for the user's gnome-shell to answer (default 300)
  QUALIFY_LOCK_TIMEOUT  seconds loginctl lock-session and unlock-session may take to show
                        in gnome-shell's state (default 60)
  QUALIFY_G4_RECORD     the G4 key of the last local pass (default _build/g4-passed.txt)
  QUALIFY_KEEP_DISKS    1 keeps the VM disks after each scenario
  OVMF_CODE, OVMF_VARS, OVMF_FORMAT  firmware files (auto-detected on Ubuntu, Fedora)
EOF
    exit 2
}

: "${QUALIFY_OUT:=$APEX_ROOT/_build/qualify}"
# GRUB cannot save its environment block on btrfs, and to-disk puts /boot on the btrfs
# root: the boot counter is tested on an ext4 /boot, as the laptop runs it.
: "${QUALIFY_LAYOUT:=separate-boot}"
: "${QUALIFY_DISK_GB:=40}"
: "${QUALIFY_MEM:=6G}"
: "${QUALIFY_SMP:=4}"
: "${QUALIFY_SSH_PORT:=2222}"
: "${QUALIFY_BOOT_TIMEOUT:=900}"
: "${QUALIFY_ATTEMPT_TIMEOUT:=$((QUALIFY_BOOT_TIMEOUT + 300))}"
: "${QUALIFY_POLL:=5}"
: "${QUALIFY_LOGIN_TIMEOUT:=300}"
: "${QUALIFY_LOCK_TIMEOUT:=60}"
: "${QUALIFY_G4_RECORD:=$APEX_ROOT/_build/g4-passed.txt}"

readonly STRICT_POLICY=/usr/share/apex/containers/policy.json
readonly GRUBENV=/boot/grub2/grubenv
readonly GUEST_TMP=/var/tmp/apex-qualify
readonly ALLOWED_FAILURES="$APEX_ROOT/.github/scripts/qualify-allowed-failures.txt"
readonly APEX_STATE=/var/lib/apex
# Must match crate apex-boot: checks::force_red::FORCE_RED_PATH, checks::names::FORCED_RED.
readonly FORCE_RED=$APEX_STATE/force-red
readonly FORCED_RED_CHECK=forced-red
readonly MANIFEST=/usr/share/apex/manifest.json
readonly ASSESS_UNIT=apex-boot-assess.service
readonly BOOTLOADER_UNIT=bootloader-update.service
readonly BOOTLOADER_GATE=/usr/lib/systemd/system/bootloader-update.service.d/10-apex-after-green-boot.conf
readonly TEST_USER=apexqa
readonly LOCAL_CANDIDATE=localhost/apex-qualify:candidate
readonly G4_TRIGGER_PACKAGES=(gdm gnome-shell mutter gjs gnome-session accountsservice pam systemd
    kernel shim-x64 grub2-efi-x64 bootupd)
# Their releases carry the commit, so their files, not their NEVRAs, key G4.
readonly G4_PACKAGES_KEYED_BY_FILE_DIGEST=(apex apex-desktop)
readonly G4_TRIGGER_DIRS=(/usr/lib/bootc/kargs.d)
readonly G4_OVERLAY=$APEX_ROOT/image/system_files
readonly G4_MAX_AGE_DAYS=7
readonly G4_NOT_DUE=3
readonly APEX_SCHEMA=io.github.sekirokenjii.Apex.Desktop
readonly CRASH_GUARD_MARKER=apex-shell-starting
readonly CRASH_GUARD_TRIPPED=.local/state/apex/shell-guard-tripped
readonly TEST_FAULT_FILE=.config/environment.d/90-apex-qualify-fault.conf
readonly APEX_FAILURE='Apex: (the layer did not load|hook .* threw|enable failed|feature .* off for this session|safe mode)'

VM_NAME=
VM_SERIAL=
QMP_SOCKET=
SESSION_ID=
SESSION_UID=
SESSION_TYPE=
TEST_PASSWORD=
LOCAL_CANDIDATE_DIGEST=
declare -a LOOPS=() MOUNTS=()

result() {
    local test=$1 status=$2 detail=$3
    printf '| %s | %s | %s |\n' "$test" "$status" "$detail" >>"$QUALIFY_OUT/results.md"
    log "[$status] $test: $detail"
}

fail() {
    result "$1" "FAIL" "$2"
    die "$1: $2"
}

publish_results() {
    [[ -f $QUALIFY_OUT/results.md ]] || return 0
    summary "### Qualification (${QUALIFY_LAYOUT})" "" "| Test | Result | Detail |" "|---|---|---|" \
        "$(cat "$QUALIFY_OUT/results.md")"
}

find_ovmf() {
    if [[ -n ${OVMF_CODE:-} && -n ${OVMF_VARS:-} ]]; then
        : "${OVMF_FORMAT:=raw}"
        return
    fi
    local pair code vars fmt
    for pair in \
        "/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd raw" \
        "/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd raw" \
        "/usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_VARS.fd raw" \
        "/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2 /usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2 qcow2"; do
        read -r code vars fmt <<<"$pair"
        if [[ -r $code && -r $vars ]]; then
            OVMF_CODE=$code OVMF_VARS=$vars OVMF_FORMAT=$fmt
            return
        fi
    done
    die "no OVMF firmware found; install ovmf (Ubuntu) or edk2-ovmf (Fedora), or set OVMF_CODE/OVMF_VARS"
}

require_kvm() {
    [[ -w /dev/kvm ]] || die "/dev/kvm is not writable (run 'qualify.sh host-setup' on a runner)"
}

candidate_ref() {
    local ref=$1
    [[ $ref != sha256:* ]] || ref="$APEX_REPO_TESTING@$ref"
    [[ $ref =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$ ]] ||
        die "expected REPO@sha256:<64 hex> or sha256:<64 hex>, got '$1'"
    printf '%s\n' "$ref"
}

digest_of() { printf '%s\n' "${1##*@}"; }
repo_of() { printf '%s\n' "${1%@*}"; }
channel_of() { printf '%s:%s\n' "$(repo_of "$1")" "$APEX_FEDORA"; }

podman_pull() {
    [[ $1 != localhost/* ]] || return 0
    local -a auth=()
    [[ -z ${REGISTRY_AUTH_FILE:-} ]] || auth=(--authfile "$REGISTRY_AUTH_FILE")
    retry 5 15 as_root podman pull --quiet "${auth[@]}" "$1" >/dev/null
}

ensure_key() {
    [[ -f $QUALIFY_OUT/key ]] && return
    ssh-keygen -q -t ed25519 -N '' -C apex-qualify -f "$QUALIFY_OUT/key"
    cp "$QUALIFY_OUT/key.pub" "$QUALIFY_OUT/authorized_keys"
}

# Qualification must not depend on Flathub: these fetch about 1 GB and hold
# is-system-running in "starting" meanwhile. Install-time kargs reach every later boot.
readonly QUALIFY_MASKED_UNITS=(
    apex-flatpak-preinstall.service
    apex-flatpak-preinstall.timer
    apex-flatpak-update.service
    apex-flatpak-update.timer
)

install_kargs() {
    local unit
    printf '%s\n' --karg console=tty0 --karg "console=ttyS0,115200n8" --karg systemd.wants=sshd.service
    for unit in "${QUALIFY_MASKED_UNITS[@]}"; do
        printf '%s\n' --karg "systemd.mask=$unit"
    done
}

install_disk() {
    local name=$1 image=$2 target=$3 disk="$QUALIFY_OUT/$1.raw"
    group "Install $image ($QUALIFY_LAYOUT) into $disk"
    podman_pull "$image"
    as_root podman run --rm --net=none --entrypoint /usr/bin/test "$image" -x /usr/sbin/sshd ||
        die "$image has no /usr/sbin/sshd: qualification needs openssh-server in the image"
    rm -f "$disk" "$QUALIFY_OUT/$name.vars"
    truncate -s "${QUALIFY_DISK_GB}G" "$disk"

    local -a common=(--rm --privileged --pid=host --security-opt label=type:unconfined_t
        -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$QUALIFY_OUT:/out")
    if [[ -d /sys/kernel/security/apparmor ]]; then
        common+=(--security-opt apparmor=unconfined)
    fi
    local -a kargs
    mapfile -t kargs < <(install_kargs)

    case $QUALIFY_LAYOUT in
        to-disk)
            as_root podman run "${common[@]}" "$image" \
                bootc install to-disk --via-loopback --filesystem btrfs \
                --target-imgref "$target" --root-ssh-authorized-keys /out/authorized_keys \
                "${kargs[@]}" "/out/$name.raw"
            ;;
        separate-boot)
            local loop mnt="$QUALIFY_OUT/mnt-$name"
            loop=$(as_root losetup --find --show --partscan "$disk")
            LOOPS+=("$loop")
            # The laptop's layout minus LUKS; root carries the DPS root partition type.
            as_root sfdisk --quiet --wipe always "$loop" <<'EOF'
label: gpt
size=600MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
size=1GiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="boot"
type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root"
EOF
            as_root partx --update "$loop" 2>/dev/null || true
            as_root udevadm settle 2>/dev/null || true
            as_root mkfs.vfat -F 32 -n EFI-SYSTEM "${loop}p1" >/dev/null
            as_root mkfs.ext4 -q -F -L boot "${loop}p2"
            as_root mkfs.btrfs -q -f -L root "${loop}p3"
            mkdir -p "$mnt"
            as_root mount "${loop}p3" "$mnt"
            MOUNTS+=("$mnt")
            as_root mkdir -p "$mnt/boot"
            as_root mount "${loop}p2" "$mnt/boot"
            MOUNTS+=("$mnt/boot")
            as_root mkdir -p "$mnt/boot/efi"
            as_root mount "${loop}p1" "$mnt/boot/efi"
            MOUNTS+=("$mnt/boot/efi")
            # --generic-image: this runs on the host, whose EFI variables must stay untouched.
            as_root podman run "${common[@]}" -v "$mnt:/target" "$image" \
                bootc install to-filesystem --generic-image \
                --target-imgref "$target" --root-ssh-authorized-keys /out/authorized_keys \
                "${kargs[@]}" /target
            unmount_all
            as_root losetup --detach "$loop"
            LOOPS=()
            ;;
        *) die "QUALIFY_LAYOUT must be separate-boot or to-disk" ;;
    esac
    endgroup
}

drop_disk() {
    [[ ${QUALIFY_KEEP_DISKS:-0} == 1 ]] || rm -f "$QUALIFY_OUT/$1.raw" "$QUALIFY_OUT/$1.vars"
}

unmount_all() {
    local i
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        as_root umount "${MOUNTS[i]}" 2>/dev/null || as_root umount -l "${MOUNTS[i]}" || true
    done
    MOUNTS=()
}

# QEMU truncates the console log, so a boot whose log must survive the next start passes its own.
start_vm() {
    local name=$1 log=${2:-$1}
    shift "$(($# < 2 ? $# : 2))"
    local disk="$QUALIFY_OUT/$name.raw" vars="$QUALIFY_OUT/$name.vars"
    find_ovmf
    [[ -f $vars ]] || cp "$OVMF_VARS" "$vars"
    require_kvm
    VM_NAME=$name
    VM_SERIAL="$QUALIFY_OUT/logs/$log.serial.log"
    # A socket, not a TCP port: user networking lets the guest reach the host's loopback,
    # and QMP runs commands as the QEMU user.
    install -d -m 0700 "$QUALIFY_OUT/qmp"
    QMP_SOCKET=$QUALIFY_OUT/qmp/$name.sock
    rm -f "$QUALIFY_OUT/$name.pid" "$QMP_SOCKET"
    qemu-system-x86_64 -name "apex-$name" -machine q35,accel=kvm -cpu host \
        -m "$QUALIFY_MEM" -smp "$QUALIFY_SMP" \
        -drive "if=pflash,format=$OVMF_FORMAT,unit=0,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=$OVMF_FORMAT,unit=1,file=$vars" \
        -drive "file=$disk,format=raw,if=virtio,cache=writeback,discard=unmap" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$QUALIFY_SSH_PORT-:22" \
        -device virtio-net-pci,netdev=net0 -device virtio-rng-pci \
        -device virtio-vga -display none \
        -serial "file:$VM_SERIAL" -monitor none \
        -qmp "unix:$QMP_SOCKET,server=on,wait=off" \
        -pidfile "$QUALIFY_OUT/$name.pid" -daemonize "$@"
    log "started VM $name (pid $(cat "$QUALIFY_OUT/$name.pid"))${*:+ with $*}; console: $VM_SERIAL"
}

vm_alive() {
    [[ -n $VM_NAME && -f $QUALIFY_OUT/$VM_NAME.pid ]] && kill -0 "$(cat "$QUALIFY_OUT/$VM_NAME.pid")" 2>/dev/null
}

wait_vm_exit() {
    local deadline=$((SECONDS + $1))
    while vm_alive; do
        ((SECONDS < deadline)) || return 1
        sleep "$QUALIFY_POLL"
    done
}

stop_vm() {
    vm_alive || { VM_NAME=; return 0; }
    local pid
    pid=$(cat "$QUALIFY_OUT/$VM_NAME.pid")
    vm_ssh 'systemctl poweroff' >/dev/null 2>&1 || true
    local i
    for ((i = 0; i < 60; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 2
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for ((i = 0; i < 10; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    VM_NAME=
}

# Unlike stop_vm, never kills QEMU: ostree finalizes a staged deployment during shutdown.
poweroff_vm() {
    local test=$1
    vm_ssh 'systemctl poweroff' >/dev/null 2>&1 || true
    wait_vm_exit "$QUALIFY_BOOT_TIMEOUT" ||
        fail "$test" "the VM did not power off within ${QUALIFY_BOOT_TIMEOUT}s (staged deployment not finalized?)"
    VM_NAME=
}

vm_ssh() {
    ssh -i "$QUALIFY_OUT/key" -p "$QUALIFY_SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
        root@127.0.0.1 -- "$@"
}

wait_ssh() {
    local exit_hint=${1:-} deadline=$((SECONDS + QUALIFY_BOOT_TIMEOUT))
    while ((SECONDS < deadline)); do
        if ! vm_alive; then
            tail -n 80 "$VM_SERIAL" >&2 || true
            die "VM $VM_NAME exited${exit_hint:+: $exit_hint}"
        fi
        # QEMU's user network accepts the TCP connection before the guest listens, so
        # bound the whole attempt, banner exchange included.
        if timeout 60 ssh -i "$QUALIFY_OUT/key" -p "$QUALIFY_SSH_PORT" -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
            -o ConnectTimeout=10 root@127.0.0.1 true 2>/dev/null; then
            return 0
        fi
        sleep 10
    done
    tail -n 80 "$VM_SERIAL" >&2 || true
    die "no SSH from VM $VM_NAME after ${QUALIFY_BOOT_TIMEOUT}s (serial log above)"
}

vm_reboot() {
    local before after deadline
    before=$(vm_ssh cat /proc/sys/kernel/random/boot_id)
    vm_ssh 'systemctl reboot' >/dev/null 2>&1 || true
    deadline=$((SECONDS + QUALIFY_BOOT_TIMEOUT))
    while ((SECONDS < deadline)); do
        sleep 15
        after=$(timeout 60 ssh -i "$QUALIFY_OUT/key" -p "$QUALIFY_SSH_PORT" -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 \
            root@127.0.0.1 cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [[ -n $after && $after != "$before" ]]; then return 0; fi
        vm_alive || die "VM $VM_NAME exited during reboot"
    done
    die "VM $VM_NAME did not come back after reboot"
}

status_json() { vm_ssh 'bootc status --format=json --format-version=1'; }

# bootupd creates grubenv at install, so a missing file means boot counting is broken.
grubenv() { vm_ssh "grub2-editenv $GRUBENV list"; }

save_journal() {
    vm_alive || return 0
    vm_ssh 'journalctl -b --no-pager -o short-monotonic' >"$QUALIFY_OUT/logs/$VM_NAME-$1.journal.txt" 2>/dev/null || true
    vm_ssh 'systemctl list-units --state=failed --no-pager; systemctl status --no-pager apex-boot-assess.service' \
        >"$QUALIFY_OUT/logs/$VM_NAME-$1.units.txt" 2>&1 || true
}

save_bootc_status_fixture() {
    local name=$1 version dir
    version=$(vm_ssh 'rpm -q --queryformat "%{version}-%{release}" bootc' 2>/dev/null || echo unknown)
    dir="$QUALIFY_OUT/fixtures/bootc-$version"
    mkdir -p "$dir"
    status_json >"$dir/$name.json"
    jq -e . "$dir/$name.json" >/dev/null || fail "fixture $name" "bootc status is not JSON"
}

unexpected_failures() {
    comm -23 <(awk '{print $1}' | sed '/^$/d' | sort) \
        <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_FAILURES" | sed '/^$/d' | sort)
}

assert_running() {
    local test=$1 state unexpected
    state=$(vm_ssh 'timeout 900 systemctl is-system-running --wait' 2>/dev/null || true)
    case $state in
        running) ;;
        degraded)
            unexpected=$(vm_ssh 'systemctl list-units --state=failed --plain --no-legend --no-pager' |
                unexpected_failures)
            if [[ -n $unexpected ]]; then
                save_journal "$test"
                fail "$test" "system degraded; failed units: $(tr '\n' ' ' <<<"$unexpected")"
            fi
            ;;
        *)
            save_journal "$test"
            fail "$test" "systemctl is-system-running: '${state:-no answer}'"
            ;;
    esac
}

wait_assessment() {
    local test=$1 props deadline=$((SECONDS + 600)) exit_ts active res code
    while true; do
        props=$(vm_ssh 'systemctl show apex-boot-assess.service -p ActiveState -p Result -p ExecMainStatus -p ExecMainExitTimestampMonotonic')
        exit_ts=$(sed -n 's/^ExecMainExitTimestampMonotonic=//p' <<<"$props")
        active=$(sed -n 's/^ActiveState=//p' <<<"$props")
        [[ ${exit_ts:-0} == 0 || $active == activating ]] || break
        ((SECONDS < deadline)) || { save_journal "$test"; fail "$test" "apex-boot-assess.service did not finish within 10 min"; }
        sleep 10
    done
    res=$(sed -n 's/^Result=//p' <<<"$props")
    code=$(sed -n 's/^ExecMainStatus=//p' <<<"$props")
    if [[ $res != success || $code != 0 ]]; then
        save_journal "$test"
        fail "$test" "apex-boot-assess.service Result=$res ExecMainStatus=$code"
    fi
}

assert_grubenv() {
    local test=$1 env problem
    env=$(grubenv) || fail "$test" "cannot read $GRUBENV"
    problem=$(grubenv_check "${@:2}" <<<"$env") ||
        fail "$test" "grubenv: $problem (all: $(tr '\n' ' ' <<<"$env"))"
}

assert_green() {
    local test=$1 expected=$2 grubstate=${3:-disarmed} status booted
    assert_running "$test"
    wait_assessment "$test"
    assert_grubenv "$test" "$grubstate"

    status=$(status_json)
    booted=$(jq -r '.status.booted.image.imageDigest // empty' <<<"$status")
    [[ $booted == "$expected" ]] || fail "$test" "booted digest is '$booted', expected $expected"
    local root_mount
    root_mount=$(vm_ssh 'findmnt -n -o FSTYPE,SOURCE /' | awk '{ print $1, $2 }')
    [[ $root_mount == "overlay composefs" ]] || fail "$test" "/ is '$root_mount', not composefs's overlay"

    local apexctl
    apexctl=$(vm_ssh 'apexctl status --json') || fail "$test" "apexctl status --json failed"
    jq -e 'type == "object"' <<<"$apexctl" >/dev/null || fail "$test" "apexctl status --json is not a JSON object"
    printf '%s\n' "$apexctl" >"$QUALIFY_OUT/fixtures/apexctl-status-$test.json"

    result "$test" PASS "running, apex-boot-assess green, grubenv $grubstate, booted $expected on composefs"
}

expect_rejected() {
    local test=$1 cmd=$2 out rc=0
    out=$(vm_ssh "$cmd" 2>&1) || rc=$?
    printf '%s\n' "$out" >"$QUALIFY_OUT/logs/negative-$test.txt"
    ((rc != 0)) || fail "$test" "accepted: $cmd"
    grep -Eqi 'signature|rejected|verif|policy' <<<"$out" ||
        fail "$test" "failed for a reason other than signature policy: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
    local staged
    staged=$(status_json | jq -r '.status.staged // empty')
    [[ -z $staged ]] || fail "$test" "a staged deployment exists after the rejected pull"
    result "$test" PASS "rejected: $(grep -Ei -m1 'signature|rejected|verif|policy' <<<"$out" | cut -c1-160)"
}

negative_tests() {
    local candidate=$1 wrong_pub policy
    vm_ssh "mkdir -p $GUEST_TMP/no-registries.d"
    wrong_pub=$(openssl ecparam -name prime256v1 -genkey -noout | openssl ec -pubout 2>/dev/null)
    vm_ssh "cat > $GUEST_TMP/wrong.pub" <<<"$wrong_pub"
    policy=$(vm_ssh "cat $STRICT_POLICY") || fail "policy" "$STRICT_POLICY missing in the image"
    policy_rejects_by_default <<<"$policy" || fail "policy" "$STRICT_POLICY does not default to reject"
    policy_single_key "$GUEST_TMP/wrong.pub" <<<"$policy" | vm_ssh "cat > $GUEST_TMP/wrong-policy.json"

    expect_rejected wrong-key \
        "CONTAINERS_POLICY_JSON=$GUEST_TMP/wrong-policy.json bootc switch --enforce-container-sigpolicy --download-only $candidate"
    expect_rejected foreign-registry \
        "CONTAINERS_POLICY_JSON=$STRICT_POLICY bootc switch --enforce-container-sigpolicy --download-only registry.fedoraproject.org/fedora-bootc:$APEX_FEDORA"
    # An empty registries.d disables sigstore lookups: the candidate then looks unsigned.
    if vm_ssh 'command -v skopeo' >/dev/null 2>&1; then
        expect_rejected no-signature \
            "timeout 300 skopeo --policy $STRICT_POLICY --registries.d $GUEST_TMP/no-registries.d copy docker://$candidate dir:$GUEST_TMP/unsigned-copy; rc=\$?; rm -rf $GUEST_TMP/unsigned-copy; exit \$rc"
    else
        result no-signature SKIP "skopeo is not in the image"
    fi
}

download_only_test() {
    local candidate=$1 cand_digest target="" target_digest rc spec
    cand_digest=$(digest_of "$candidate")
    rc=0
    target_digest=$(registry_digest "$APEX_REPO_STABLE:$APEX_FEDORA") || rc=$?
    if ((rc == 0)) && [[ $target_digest != "$cand_digest" ]]; then
        target="$APEX_REPO_STABLE:$APEX_FEDORA"
    else
        rc=0
        target_digest=$(registry_digest "$APEX_REPO_TESTING:$APEX_FEDORA") || rc=$?
        if ((rc == 0)) && [[ $target_digest != "$cand_digest" ]]; then
            target="$APEX_REPO_TESTING:$APEX_FEDORA"
        fi
    fi
    if [[ -z $target ]]; then
        result download-only-reboot SKIP "no published image other than the candidate to stage"
        notice "download-only reboot test skipped: apex:$APEX_FEDORA and apex-testing:$APEX_FEDORA are absent or equal the candidate"
        return 0
    fi

    local before after stage_cmd
    before=$(status_json | jq -c '.status.booted.ostree | {checksum, deploySerial}')
    spec=$(status_json | jq -r '.spec.image.image // empty')
    if [[ $spec == "$target" ]]; then
        stage_cmd="CONTAINERS_POLICY_JSON=$STRICT_POLICY bootc upgrade --download-only"
    else
        stage_cmd="CONTAINERS_POLICY_JSON=$STRICT_POLICY bootc switch --enforce-container-sigpolicy --download-only $target"
    fi
    vm_ssh "timeout 3600 $stage_cmd" || fail download-only-stage "staging $target failed"
    local status
    status=$(status_json)
    jq -e '.status.staged.downloadOnly == true' <<<"$status" >/dev/null ||
        fail download-only-stage "the staged deployment is not download-only"
    [[ $(jq -r '.status.staged.image.imageDigest' <<<"$status") == "$target_digest" ]] ||
        fail download-only-stage "staged digest differs from $target ($target_digest)"
    save_bootc_status_fixture staged-download-only
    assert_grubenv download-only-stage disarmed
    result download-only-stage PASS "staged $target ($target_digest), locked, boot counter not armed"

    vm_reboot
    assert_green download-only-reboot "$cand_digest"
    status=$(status_json)
    after=$(jq -c '.status.booted.ostree | {checksum, deploySerial}' <<<"$status")
    [[ $after == "$before" ]] || fail download-only-reboot "booted deployment changed: $before -> $after"
    [[ $(jq -r '.status.staged // empty' <<<"$status") == "" ]] ||
        fail download-only-reboot "the locked stage survived the reboot"
}

stage_candidate() {
    local test=$1 candidate=$2 digest status
    digest=$(digest_of "$candidate")
    vm_ssh "timeout 3600 env CONTAINERS_POLICY_JSON=$STRICT_POLICY bootc switch --enforce-container-sigpolicy --download-only $candidate" ||
        fail "$test" "bootc switch to $candidate failed (CI signature not accepted?)"
    status=$(status_json)
    [[ $(jq -r '.status.staged.image.imageDigest // empty' <<<"$status") == "$digest" ]] ||
        fail "$test" "staged digest is not $digest"
    jq -e '.status.staged.downloadOnly == true' <<<"$status" >/dev/null ||
        fail "$test" "the staged deployment is not download-only"
    assert_grubenv "$test" disarmed
    result "$test" PASS "staged $digest download-only under the strict policy"
}

# Apply arms only when a different image is staged and the booted one is neither armed nor
# named by health-failure.json, all of which a fresh install meets.
apply_candidate() {
    local test=$1 digest=$2 fixture=$3
    vm_ssh "apexctl update apply --digest $digest" || fail "$test" "apexctl update apply failed"
    assert_grubenv "$test" armed "$digest"
    status_json | jq -e '.status.staged != null and ((.status.staged.downloadOnly // false) | not)' >/dev/null ||
        fail "$test" "the stage is still locked (or gone) after Apply"
    save_bootc_status_fixture "$fixture"
    result "$test" PASS "apexctl update apply armed apex_target=$digest apex_counter=$APEX_BOOT_ATTEMPTS and unlocked the stage"
}

# apex-boot-assess ignores the hook unless it and its directory are writable by root only.
set_force_red() {
    local test=$1-hook digest=$2 mode
    is_digest "$digest" || die "set_force_red: invalid digest '$digest'"
    local hook_size=$((${#digest} + 1))
    vm_ssh "install -d -m 0700 $APEX_STATE && (umask 077 && printf '%s\n' $digest > $FORCE_RED.tmp) && mv -f $FORCE_RED.tmp $FORCE_RED" ||
        fail "$test" "cannot write $FORCE_RED"
    mode=$(vm_ssh "stat -c '%a %U %s' $FORCE_RED $APEX_STATE" | tr '\n' ' ')
    [[ $mode == "600 root $hook_size 700 root "* ]] || fail "$test" "unexpected mode/owner/size of the hook: $mode"
    result "$test" PASS "$FORCE_RED names $digest"
}

# With -no-reboot every guest reboot ends QEMU, which counts the attempts. Nothing may log
# in: apex-boot-assess never reboots while a user session exists.
armed_attempts() {
    local name=$1 attempts=$2 n
    group "Boot the armed target of $name without logging in (expect $attempts self-reboots)"
    for ((n = 1; n <= attempts; n++)); do
        start_vm "$name" "$name-attempt$n" -no-reboot
        wait_vm_exit "$QUALIFY_ATTEMPT_TIMEOUT" ||
            fail "$name-attempt$n" "the armed, failing boot did not reboot itself within ${QUALIFY_ATTEMPT_TIMEOUT}s"
        result "$name-attempt$n" PASS "the guest rebooted itself (console: logs/$name-attempt$n.serial.log)"
    done
    start_vm "$name" "$name-fallback" -no-reboot
    endgroup
}

journal_boot_count() {
    vm_ssh 'journalctl --list-boots --no-pager 2>/dev/null' | grep -cE '^[[:space:]]*-?[0-9]+[[:space:]]' || true
}

# Prints nothing, not 0, when the journal is not persistent, so the caller can tell unknown from none.
forced_red_boots() {
    local n=$1 count=0 b
    (($(journal_boot_count) > n)) || return 0
    for ((b = 1; b <= n; b++)); do
        if vm_ssh "journalctl -b -$b -u apex-boot-assess.service -o cat --no-pager -q | grep -q -- $FORCED_RED_CHECK"; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

assert_counted_rollback() {
    local test=$1 previous=$2 target=$3 status booted file
    assert_running "$test"
    wait_assessment "$test"
    assert_grubenv "$test" disarmed

    status=$(status_json)
    printf '%s\n' "$status" >"$QUALIFY_OUT/logs/$test.bootc-status.json"
    booted=$(jq -r '.status.booted.image.imageDigest // empty' <<<"$status")
    [[ $booted == "$previous" ]] ||
        fail "$test" "booted digest is '$booted', expected the previous image $previous (GRUB did not fall back?)"
    jq -e '(.status.rollbackQueued // false) | not' <<<"$status" >/dev/null ||
        fail "$test" "rollbackQueued is still true: the failed target stays the default (bootc rollback did not run)"
    [[ $(jq -r '.status.rollback.image.imageDigest // empty' <<<"$status") == "$target" ]] ||
        fail "$test" "the rollback deployment is not the failed target $target"
    [[ -z $(jq -r '.status.staged // empty' <<<"$status") ]] || fail "$test" "a staged deployment exists after the rollback"
    save_bootc_status_fixture counted-rollback

    file=$(vm_ssh "cat $APEX_STATE/denylist.json") || fail "$test" "$APEX_STATE/denylist.json is missing"
    denylist_has "$target" <<<"$file" || fail "$test" "$target is not in the denylist: $file"
    ! vm_ssh "test -e $APEX_STATE/intent.json" || fail "$test" "$APEX_STATE/intent.json survived the rollback"
    file=$(vm_ssh "cat $APEX_STATE/health-failure.json") || fail "$test" "no $APEX_STATE/health-failure.json"
    health_failure_has "$target" "$FORCED_RED_CHECK" <<<"$file" ||
        fail "$test" "the health failure does not name $target with $FORCED_RED_CHECK: $file"

    local forced
    forced=$(forced_red_boots "$APEX_BOOT_ATTEMPTS")
    if [[ -z $forced ]]; then
        warn "$test: the journal is not persistent; the $APEX_BOOT_ATTEMPTS attempts are counted by QEMU exits only"
    elif ((forced != APEX_BOOT_ATTEMPTS)); then
        fail "$test" "only $forced of the $APEX_BOOT_ATTEMPTS boots before the fallback logged the $FORCED_RED_CHECK check"
    fi
    vm_ssh 'journalctl --no-pager -o short-monotonic -u apex-boot-assess.service -u apex-updated.service' \
        >"$QUALIFY_OUT/logs/$test.assess-all-boots.txt" 2>&1 || true

    result "$test" PASS "GRUB fell back after $APEX_BOOT_ATTEMPTS attempts; $previous is the default again, $target denylisted, grubenv disarmed${forced:+, forced-red in $forced journaled boots}"
}

unit_props() {
    local cmd="systemctl show $1" p
    for p in "${@:2}"; do cmd+=" -p $p"; done
    vm_ssh "$cmd"
}

prop() { sed -n "s/^$1=//p"; }

wait_no_job() {
    local test=$1 unit=$2 deadline=$((SECONDS + 600))
    while [[ -n $(vm_ssh "systemctl show -p Job --value $unit") ]]; do
        ((SECONDS < deadline)) || fail "$test" "$unit still has a job after 600 s"
        sleep "$QUALIFY_POLL"
    done
}

bootloader_gated() { vm_ssh "test -f $BOOTLOADER_GATE"; }

# Every run of `bootupctl update` logs at least one line, so no line means it did not run.
bootupctl_lines() {
    local boot=$1
    vm_ssh "journalctl -b $boot _SYSTEMD_UNIT=$BOOTLOADER_UNIT SYSLOG_IDENTIFIER=bootupctl -o cat --no-pager -q"
}

save_unit_journal() {
    local test=$1 unit=$2
    vm_ssh "journalctl -b -u $unit -o short-monotonic --no-pager" >"$QUALIFY_OUT/logs/$test.journal.txt" 2>&1 || true
}

assert_bootloader_updated() {
    local test=$1-bootloader props assessed started said cycle
    bootloader_gated || fail "$test" "the booted image has no $BOOTLOADER_GATE"
    wait_no_job "$test" "$BOOTLOADER_UNIT"
    cycle=$(vm_ssh "journalctl -b 0 _PID=1 -o cat --no-pager -q | grep -m 2 'ordering cycle'") || true
    [[ -z $cycle ]] || fail "$test" "systemd broke an ordering cycle at boot: $(tr '\n' ' ' <<<"$cycle")"
    props=$(unit_props "$BOOTLOADER_UNIT" ActiveState Result ExecMainStatus ExecMainStartTimestampMonotonic) ||
        fail "$test" "cannot read the state of $BOOTLOADER_UNIT"
    assessed=$(unit_props "$ASSESS_UNIT" ExecMainExitTimestampMonotonic | prop ExecMainExitTimestampMonotonic) ||
        fail "$test" "cannot read the state of $ASSESS_UNIT"
    save_unit_journal "$test" "$BOOTLOADER_UNIT"
    [[ $(prop ActiveState <<<"$props") == active && $(prop Result <<<"$props") == success &&
        $(prop ExecMainStatus <<<"$props") == 0 ]] ||
        fail "$test" "$BOOTLOADER_UNIT did not succeed after a green boot: $(tr '\n' ' ' <<<"$props")"
    started=$(prop ExecMainStartTimestampMonotonic <<<"$props")
    ((${started:-0} > 0 && ${assessed:-0} > 0 && started >= assessed)) ||
        fail "$test" "bootupctl started at ${started:-?} us, apex-boot-assess finished at ${assessed:-?} us"
    said=$(bootupctl_lines 0 | tail -n 1) || true
    [[ -n $said ]] || fail "$test" "bootupctl left no line in this boot's journal, so a red boot's silence would prove nothing"
    result "$test" PASS "bootupctl ran $(((started - assessed) / 1000)) ms after the green assessment and succeeded: $said"
}

# A skipped unit may have been unloaded since, so systemd's own log line counts too.
assert_bootloader_skipped() {
    local test=$1-bootloader props said
    wait_no_job "$test" "$BOOTLOADER_UNIT"
    props=$(unit_props "$BOOTLOADER_UNIT" ActiveState Result ExecMainStartTimestampMonotonic) ||
        fail "$test" "cannot read the state of $BOOTLOADER_UNIT"
    save_unit_journal "$test" "$BOOTLOADER_UNIT"
    [[ $(prop ExecMainStartTimestampMonotonic <<<"$props") == 0 && -z $(bootupctl_lines 0) ]] ||
        fail "$test" "bootupctl ran on a boot that apex-boot-assess did not judge green"
    [[ $(prop Result <<<"$props") == exec-condition ||
        -n $(vm_ssh "journalctl -b 0 UNIT=$BOOTLOADER_UNIT UNIT_RESULT=exec-condition -o cat --no-pager -q") ]] ||
        fail "$test" "no sign that the green-boot condition skipped $BOOTLOADER_UNIT (Result=exec-condition): $(tr '\n' ' ' <<<"$props")"
    said=$(vm_ssh "journalctl -b 0 _SYSTEMD_UNIT=$BOOTLOADER_UNIT SYSLOG_IDENTIFIER=sh -o cat --no-pager -q" | tail -n 1) || true
    result "$test" PASS "skipped by its condition: ${said:-no line}"
}

save_attempt_journals() {
    local name=$1 n=$2 b
    for ((b = n; b >= 1; b--)); do
        vm_ssh "journalctl -b -$b -o short-monotonic --no-pager _PID=1 + _SYSTEMD_UNIT=$ASSESS_UNIT" \
            >"$QUALIFY_OUT/logs/$name-attempt$((n - b + 1)).boot.journal.txt" 2>&1 || true
    done
}

assert_bootloader_quiet_before() {
    local test=$1-bootloader n=$2 b ran=
    if (($(journal_boot_count) <= n)); then
        result "$test" SKIP "the journal is not persistent"
        return 0
    fi
    for ((b = 1; b <= n; b++)); do
        [[ -z $(bootupctl_lines "-$b") ]] || ran+=" -$b"
    done
    [[ -z $ran ]] || fail "$test" "bootupctl ran in the red boots$ran (journalctl -b)"
    result "$test" PASS "bootupctl ran in none of the $n red boots, which reboot themselves after the assessment; the fallback row proves the green-boot condition"
}

# Before the counted boots too: without a user GDM starts gnome-initial-setup, not its greeter.
create_test_user() {
    local test=$1-user uid
    vm_ssh "id -u $TEST_USER >/dev/null 2>&1 || useradd --create-home --comment 'Apex qualification' $TEST_USER" ||
        fail "$test" "useradd $TEST_USER failed"
    vm_ssh "runuser -u $TEST_USER -- sh -c 'mkdir -p ~/.config && echo yes > ~/.config/gnome-initial-setup-done'" ||
        fail "$test" "cannot mark gnome-initial-setup done for $TEST_USER"
    uid=$(vm_ssh "id -u $TEST_USER") || fail "$test" "$TEST_USER does not exist after useradd"
    result "$test" PASS "$TEST_USER (uid $uid), made in this guest only, without a password"
}

find_session_script() {
    cat <<'EOF'
class=$1 name=${2:-}
for id in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    s=$(loginctl show-session "$id" -p Class -p Seat -p State -p Name -p User -p Type) || continue
    grep -qx "Class=$class" <<<"$s" && grep -qx Seat=seat0 <<<"$s" && grep -qx State=active <<<"$s" || continue
    [[ -z $name ]] || grep -qx "Name=$name" <<<"$s" || continue
    printf '%s %s %s\n' "$id" "$(sed -n 's/^User=//p' <<<"$s")" "$(sed -n 's/^Type=//p' <<<"$s")"
    exit 0
done
exit 1
EOF
}

active_session() { vm_ssh bash -s -- "$@" < <(find_session_script); }

wait_session() {
    local test=$1 class=$2 name=${3:-} deadline=$((SECONDS + QUALIFY_LOGIN_TIMEOUT)) found
    until found=$(active_session "$class" "$name"); do
        if ((SECONDS >= deadline)); then
            vm_ssh 'loginctl list-sessions --no-pager; systemctl status --no-pager gdm.service' \
                >"$QUALIFY_OUT/logs/$test.sessions.txt" 2>&1 || true
            save_journal "$test"
            fail "$test" "no active $class session${name:+ of $name} on seat0 after ${QUALIFY_LOGIN_TIMEOUT}s"
        fi
        sleep "$QUALIFY_POLL"
    done
    read -r SESSION_ID SESSION_UID SESSION_TYPE <<<"$found"
}

shell_pid() {
    local uid=$1
    vm_ssh "pgrep -u $uid -x gnome-shell"
}

assert_greeter() {
    local test=$1-greeter
    wait_session "$test" greeter
    vm_ssh 'systemctl is-active --quiet gdm.service' || fail "$test" "gdm.service is not active"
    shell_pid "$SESSION_UID" >/dev/null || fail "$test" "no gnome-shell runs for the greeter (uid $SESSION_UID)"
    result "$test" PASS "GDM's greeter: session $SESSION_ID ($SESSION_TYPE) on seat0, gnome-shell as uid $SESSION_UID"
}

# GDM's greeter lists no locked account, and useradd leaves one locked. The password lives
# in this run only and never reaches a log.
set_test_password() {
    local test=$1-password
    TEST_PASSWORD=$(openssl rand -hex 12) || fail "$test" "openssl rand failed"
    vm_ssh chpasswd <<<"$TEST_USER:$TEST_PASSWORD" || fail "$test" "chpasswd for $TEST_USER failed"
    result "$test" PASS "$TEST_USER has a password known to this run only, so GDM's greeter lists it from the next boot"
}

readonly QMP_CLIENT='
import json, socket, sys
with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(30)
    s.connect(sys.argv[1])
    stream = s.makefile("rw")
    json.loads(stream.readline())
    for command in ["{\"execute\":\"qmp_capabilities\"}"] + sys.stdin.read().splitlines():
        stream.write(command + "\n")
        stream.flush()
        while True:
            reply = json.loads(stream.readline())
            if "return" in reply:
                break
            if "error" in reply:
                sys.exit("QMP: %s" % reply["error"])
'

# On stdin, so that no key of the password reaches a process's arguments.
qmp() { printf '%s\n' "$@" | python3 -c "$QMP_CLIENT" "$QMP_SOCKET"; }

key_press() {
    local key IFS=,
    local -a keys=()
    for key in "$@"; do keys+=("{\"type\":\"qcode\",\"data\":\"$key\"}"); done
    printf '{"execute":"send-key","arguments":{"keys":[%s]}}\n' "${keys[*]}"
}

type_text() {
    local i
    local -a presses=()
    [[ $1 =~ ^[0-9a-z]*$ ]] || die "type_text: only [0-9a-z] have a qcode of their own"
    for ((i = 0; i < ${#1}; i++)); do presses+=("$(key_press "${1:i:1}")"); done
    qmp "${presses[@]}"
}

screendump() {
    qmp "$(jq -cn --arg f "$QUALIFY_OUT/logs/$1.png" '{execute: "screendump", arguments: {filename: $f, format: "png"}}')" ||
        warn "QEMU wrote no screendump logs/$1.png"
}

# The logged-in session's GDM worker runs one, and another runs while a password is asked for.
password_conversations() { vm_ssh "pgrep -c -f 'pam/gdm-passwor[d]'" || true; }

type_password_after_enter() {
    local test=$1 where=$2 before=$3 deadline=$((SECONDS + QUALIFY_LOGIN_TIMEOUT))
    until (($(password_conversations) > before)); do
        if ((SECONDS >= deadline)); then
            screendump "$test"
            save_journal "$test"
            fail "$test" "GDM started no password conversation ${QUALIFY_LOGIN_TIMEOUT}s into pressing Enter on $where (logs/$test.png)"
        fi
        qmp "$(key_press ret)" || fail "$test" "QEMU took no key on its QMP socket $QMP_SOCKET"
        sleep "$QUALIFY_POLL"
    done
    # The prompt takes keys only once the conversation has reached PAM.
    sleep "$QUALIFY_POLL"
    screendump "$test"
    { type_text "$TEST_PASSWORD" && qmp "$(key_press ret)"; } ||
        fail "$test" "QEMU took no key on its QMP socket $QMP_SOCKET"
}

# Enter picks the user GDM's greeter lists, which starts its password conversation.
greeter_login() {
    local test=$1-greeter-login
    wait_session "$test" greeter
    type_password_after_enter "$test" "GDM's greeter" 0
    wait_session "$test" user "$TEST_USER"
    result "$test" PASS "typed $TEST_USER's password into GDM's greeter (logs/$test.png): session $SESSION_ID ($SESSION_TYPE) on seat0"
}

user_run() {
    local uid=$1
    shift
    vm_ssh "runuser -u $TEST_USER -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus $*"
}

screensaver_active() {
    local uid=$1
    user_run "$uid" gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver \
        --method org.gnome.ScreenSaver.GetActive 2>/dev/null
}

shell_answers() {
    local uid=$1
    [[ $(screensaver_active "$uid") == "("*",)" ]]
}

lockedhint_and_screensaver_agree() {
    local session=$1 uid=$2 locked_hint=$3 screensaver_reply='(false,)'
    [[ $locked_hint == no ]] || screensaver_reply='(true,)'
    [[ $(vm_ssh "loginctl show-session $session -p LockedHint --value") == "$locked_hint" &&
        $(screensaver_active "$uid") == "$screensaver_reply" ]]
}

wait_until() {
    local test=$1 deadline=$((SECONDS + $2)) why=$3
    until "${@:4}"; do
        if ((SECONDS >= deadline)); then
            save_journal "$test"
            fail "$test" "$why"
        fi
        sleep "$QUALIFY_POLL"
    done
}

js_errors() {
    local log=$1
    grep -c 'JS ERROR' "$log" || true
}

user_journal() {
    local uid=$1 since=$2 out=$3
    vm_ssh "journalctl -b _UID=$uid --since @$((since - 1)) -o short-monotonic --no-pager" >"$out" 2>&1
}

# The layer creates it at enable and removes it 60 s later.
crash_guard_armed() {
    local uid=$1
    vm_ssh "test -e /run/user/$uid/$CRASH_GUARD_MARKER"
}

user_setting() {
    local uid=$1 schema=$2 key=$3
    user_run "$uid" gsettings get "$schema" "$key"
}

assert_apex_login() {
    local test=$1 since=$2 pid log errors failure scheme agents status
    wait_until "$test" "$QUALIFY_LOGIN_TIMEOUT" \
        "the layer never created /run/user/$SESSION_UID/$CRASH_GUARD_MARKER: it did not reach enable, so the crash guard was never armed" \
        crash_guard_armed "$SESSION_UID"
    wait_until "$test" "$QUALIFY_LOGIN_TIMEOUT" \
        "the gnome-shell of session $SESSION_ID never answered on org.gnome.ScreenSaver" shell_answers "$SESSION_UID"
    pid=$(shell_pid "$SESSION_UID") || fail "$test" "no gnome-shell runs as $TEST_USER"
    log=$QUALIFY_OUT/logs/$test.journal.txt
    user_journal "$SESSION_UID" "$since" "$log" || fail "$test" "cannot read the journal of $TEST_USER"
    failure=$(grep -Em 1 "$APEX_FAILURE" "$log") || true
    [[ -z $failure ]] || fail "$test" "the layer did not run cleanly: $(cut -c1-200 <<<"$failure") (logs/${log##*/})"
    scheme=$(user_setting "$SESSION_UID" org.gnome.desktop.interface color-scheme) ||
        fail "$test" "cannot read $TEST_USER's color-scheme"
    [[ $scheme == "'default'" ]] || fail "$test" "color-scheme is $scheme after login, not GNOME's 'default'"
    agents=$(user_run "$SESSION_UID" systemctl --user list-units --state=active --plain --no-legend --no-pager "'apex*'") ||
        fail "$test" "cannot list the user units of $TEST_USER"
    [[ -z $agents ]] || fail "$test" "an Apex user unit runs: $(tr '\n' ' ' <<<"$agents")"
    errors=$(js_errors "$log")
    status=PASS
    ((errors == 0)) || status=WARN
    result "$test" "$status" "$TEST_USER's session $SESSION_ID ($SESSION_TYPE) on seat0, gnome-shell pid $pid answers; the Apex layer armed its crash guard and logged no failure; color-scheme 'default', no Apex user unit; $errors JS ERROR line(s) since login (logs/${log##*/})"
}

lock_session() {
    local test=$1
    vm_ssh "loginctl lock-session $SESSION_ID" || fail "$test" "loginctl lock-session $SESSION_ID failed"
    wait_until "$test" "$QUALIFY_LOCK_TIMEOUT" \
        "session $SESSION_ID not locked ${QUALIFY_LOCK_TIMEOUT}s after loginctl lock-session" \
        lockedhint_and_screensaver_agree "$SESSION_ID" "$SESSION_UID" yes
    screendump "$test"
}

assert_unlocked() {
    local test=$1 pid=$2 since=$3 how=$4 log errors
    wait_until "$test" "$QUALIFY_LOCK_TIMEOUT" \
        "session $SESSION_ID still locked ${QUALIFY_LOCK_TIMEOUT}s after $how" \
        lockedhint_and_screensaver_agree "$SESSION_ID" "$SESSION_UID" no
    # The unlock path goes on after LockedHint drops: the fade-out and its callbacks.
    sleep "$QUALIFY_POLL"
    [[ $(shell_pid "$SESSION_UID") == "$pid" ]] ||
        fail "$test" "gnome-shell (pid $pid) did not survive the lock and unlock"
    log=$QUALIFY_OUT/logs/$test.journal.txt
    user_journal "$SESSION_UID" "$since" "$log" || fail "$test" "cannot read the journal of $TEST_USER"
    errors=$(js_errors "$log")
    ((errors == 0)) ||
        fail "$test" "$errors JS ERROR line(s) from lock to unlock (logs/${log##*/}), first: $(grep -m 1 'JS ERROR' "$log" | cut -c1-200)"
    screendump "$test-unlocked"
    result "$test" PASS "$how: LockedHint=no, org.gnome.ScreenSaver inactive, the same gnome-shell, no JS ERROR (logs/$test.png, logs/$test-unlocked.png)"
}

login_lock_unlock() {
    local name=$1 pid since failed unexpected
    since=$(vm_ssh 'date +%s') || fail "$name-login" "cannot read the guest's clock"
    wait_session "$name-login" user "$TEST_USER"
    assert_apex_login "$name-login" "$since"
    pid=$(shell_pid "$SESSION_UID")

    since=$(vm_ssh 'date +%s') || fail "$name-lock" "cannot read the guest's clock"
    lock_session "$name-lock"
    result "$name-lock" PASS "loginctl lock-session: LockedHint=yes, org.gnome.ScreenSaver active (logs/$name-lock.png)"
    type_password_after_enter "$name-unlock" "the lock screen" "$(password_conversations)"
    assert_unlocked "$name-unlock" "$pid" "$since" "the password typed into the unlock dialog"

    since=$(vm_ssh 'date +%s') || fail "$name-unlock-signal" "cannot read the guest's clock"
    lock_session "$name-unlock-signal"
    vm_ssh "loginctl unlock-session $SESSION_ID" ||
        fail "$name-unlock-signal" "loginctl unlock-session $SESSION_ID failed"
    assert_unlocked "$name-unlock-signal" "$pid" "$since" "loginctl unlock-session"

    failed=$(user_run "$SESSION_UID" systemctl --user list-units --state=failed --plain --no-legend --no-pager) ||
        fail "$name-user-units" "cannot list the user units of $TEST_USER"
    unexpected=$(unexpected_failures <<<"$failed")
    [[ -z $unexpected ]] || fail "$name-user-units" "failed user units of $TEST_USER: $(tr '\n' ' ' <<<"$unexpected")"
    result "$name-user-units" PASS "no failed user unit"
}

user_manager_gone() {
    local uid=$1
    ! vm_ssh "systemctl -q is-active user@$uid.service"
}

log_out() {
    local test=$1 uid=$2
    vm_ssh "loginctl terminate-user $TEST_USER" >/dev/null 2>&1 || true
    wait_until "$test" "$QUALIFY_LOGIN_TIMEOUT" "$TEST_USER's user manager still runs after loginctl terminate-user" \
        user_manager_gone "$uid"
}

crash_guard_logins() {
    local name=$1 uid since log errors
    uid=$(vm_ssh "id -u $TEST_USER") || fail "$name-crash-guard" "$TEST_USER does not exist"
    log_out "$name-crash-guard" "$uid"
    vm_ssh "runuser -u $TEST_USER -- sh -c 'mkdir -p ~$TEST_USER/${TEST_FAULT_FILE%/*} && echo APEX_SHELL_TEST_FAULT=abort-after-enable >~$TEST_USER/$TEST_FAULT_FILE'" ||
        fail "$name-crash-guard" "cannot write ~$TEST_USER/$TEST_FAULT_FILE"
    since=$(vm_ssh 'date +%s') || fail "$name-crash-guard" "cannot read the guest's clock"
    wait_session "$name-crash-guard" greeter
    type_password_after_enter "$name-crash-guard" "GDM's greeter" 0
    wait_until "$name-crash-guard" "$QUALIFY_LOGIN_TIMEOUT" \
        "no ~$TEST_USER/$CRASH_GUARD_TRIPPED: the crash guard did not trip" vm_ssh "test -e ~$TEST_USER/$CRASH_GUARD_TRIPPED"
    log=$QUALIFY_OUT/logs/$name-crash-guard.journal.txt
    user_journal "$uid" "$since" "$log" || fail "$name-crash-guard" "cannot read the journal of $TEST_USER"
    grep -q 'aborting the shell' "$log" || fail "$name-crash-guard" "the shell did not abort (logs/${log##*/})"
    grep -q 'Finished apex-shell-safe.service' "$log" ||
        fail "$name-crash-guard" "apex-shell-safe.service did not finish (logs/${log##*/})"
    result "$name-crash-guard" PASS "a login with APEX_SHELL_TEST_FAULT=abort-after-enable in ~/$TEST_FAULT_FILE: the shell aborted, apex-shell-safe.service ran and left ~/$CRASH_GUARD_TRIPPED (logs/${log##*/})"

    log_out "$name-safe-login" "$uid"
    vm_ssh "rm -f ~$TEST_USER/$TEST_FAULT_FILE" || fail "$name-safe-login" "cannot remove ~$TEST_USER/$TEST_FAULT_FILE"
    since=$(vm_ssh 'date +%s') || fail "$name-safe-login" "cannot read the guest's clock"
    greeter_login "$name-safe"
    wait_until "$name-safe-login" "$QUALIFY_LOGIN_TIMEOUT" \
        "the gnome-shell of session $SESSION_ID never answered on org.gnome.ScreenSaver" shell_answers "$SESSION_UID"
    log=$QUALIFY_OUT/logs/$name-safe-login.journal.txt
    user_journal "$SESSION_UID" "$since" "$log" || fail "$name-safe-login" "cannot read the journal of $TEST_USER"
    grep -q 'Apex: safe mode (layer-enabled is false)' "$log" ||
        fail "$name-safe-login" "the next login did not start in safe mode (logs/${log##*/})"
    [[ $(user_setting "$SESSION_UID" "$APEX_SCHEMA" layer-enabled) == false ]] ||
        fail "$name-safe-login" "$TEST_USER's layer-enabled is not false"
    errors=$(js_errors "$log")
    ((errors == 0)) ||
        fail "$name-safe-login" "$errors JS ERROR line(s) in the safe login (logs/${log##*/}), first: $(grep -m 1 'JS ERROR' "$log" | cut -c1-200)"
    result "$name-safe-login" PASS "the next login logged 'Apex: safe mode (layer-enabled is false)' with layer-enabled false and no JS ERROR (logs/${log##*/}); G2's guard phase 'next' proves that this start loads upstream's sheet"
}

# Apply arms only for another digest whose manifest version is higher.
stage_local_candidate() {
    local test=$1 booted=$2 manifest version status dir=$GUEST_TMP/candidate
    manifest=$(vm_ssh "cat $MANIFEST") || fail "$test" "cannot read $MANIFEST"
    version=$(jq -er '.version' <<<"$manifest").1 || fail "$test" "$MANIFEST has no version"
    vm_ssh "rm -rf $dir && mkdir -p $dir" || fail "$test" "cannot make $dir"
    jq --arg v "$version" '.version = $v' <<<"$manifest" |
        vm_ssh "cat > $dir/manifest.json && chmod 0644 $dir/manifest.json" || fail "$test" "cannot write $dir/manifest.json"
    printf 'FROM localhost/bootc\nCOPY manifest.json %s\nLABEL org.opencontainers.image.version=%s\n' "$MANIFEST" "$version" |
        vm_ssh "cat > $dir/Containerfile" ||
        fail "$test" "cannot write $dir/Containerfile"
    vm_ssh 'timeout 1800 bootc image copy-to-storage' || fail "$test" "bootc image copy-to-storage failed"
    vm_ssh "timeout 1800 podman build --pull=never --tag $LOCAL_CANDIDATE $dir" || fail "$test" "podman build of $LOCAL_CANDIDATE failed"
    vm_ssh "timeout 3600 bootc switch --transport containers-storage --download-only $LOCAL_CANDIDATE" ||
        fail "$test" "bootc switch --download-only to $LOCAL_CANDIDATE failed"
    vm_ssh "podman rmi $LOCAL_CANDIDATE localhost/bootc >/dev/null" || warn "$test: could not remove the candidate's container images"
    status=$(status_json)
    LOCAL_CANDIDATE_DIGEST=$(jq -r '.status.staged.image.imageDigest // empty' <<<"$status")
    is_digest "$LOCAL_CANDIDATE_DIGEST" || fail "$test" "bootc names no staged image digest"
    [[ $LOCAL_CANDIDATE_DIGEST != "$booted" ]] || fail "$test" "the candidate has the booted digest $booted"
    jq -e '.status.staged.downloadOnly == true' <<<"$status" >/dev/null ||
        fail "$test" "the staged deployment is not download-only"
    assert_grubenv "$test" disarmed
    result "$test" PASS "staged $LOCAL_CANDIDATE ($LOCAL_CANDIDATE_DIGEST, version $version) download-only"
}

counted_rollback() {
    local name=$1 from_digest=$2 digest=$3 status
    create_test_user "$name"
    set_force_red "$name" "$digest"
    apply_candidate "$name-apply" "$digest" "$name-staged-applied"
    save_journal baseline
    # Powered off, not rebooted: the counted boots start under -no-reboot.
    poweroff_vm "$name-apply"

    armed_attempts "$name" "$APEX_BOOT_ATTEMPTS"
    wait_ssh "the VM rebooted a $((APEX_BOOT_ATTEMPTS + 1))th time; GRUB did not fall back to $from_digest after $APEX_BOOT_ATTEMPTS attempts"
    assert_counted_rollback "$name-fallback" "$from_digest" "$digest"
    save_attempt_journals "$name" "$APEX_BOOT_ATTEMPTS"
    if bootloader_gated; then
        assert_bootloader_quiet_before "$name-attempts" "$APEX_BOOT_ATTEMPTS"
        assert_bootloader_skipped "$name-fallback"
    else
        result "$name-fallback-bootloader" SKIP "$from_digest predates $BOOTLOADER_GATE"
    fi
    save_journal fallback

    if vm_ssh 'apexctl update acknowledge --help' >/dev/null 2>&1; then
        vm_ssh 'apexctl update acknowledge' || fail "$name-acknowledge" "apexctl update acknowledge failed"
        ! vm_ssh "test -e $APEX_STATE/health-failure.json" ||
            fail "$name-acknowledge" "$APEX_STATE/health-failure.json is still there after acknowledge"
        result "$name-acknowledge" PASS "apexctl update acknowledge cleared the health failure"
    else
        result "$name-acknowledge" SKIP "$from_digest's apexctl has no 'update acknowledge'"
    fi

    stop_vm
    start_vm "$name" "$name-settled"
    wait_ssh
    assert_green "$name-settled" "$from_digest"
    if bootloader_gated; then
        assert_bootloader_updated "$name-settled"
    fi
    status=$(status_json)
    [[ $(jq -r '.status.rollback.image.imageDigest // empty' <<<"$status") == "$digest" ]] ||
        fail "$name-settled" "the failed target $digest is no longer the rollback deployment"
    vm_ssh "rm -f $FORCE_RED" || true
    assert_greeter "$name-settled"
}

g4_overlay_usr_files() {
    (cd "$G4_OVERLAY" && find usr -type f -printf '/%p\n' | LC_ALL=C sort)
}

g4_key_script() {
    local -a overlay_files
    mapfile -t overlay_files < <(g4_overlay_usr_files)
    ((${#overlay_files[@]})) || die "no /usr file in $G4_OVERLAY"
    cat <<EOF
set -eu
rpm -q --qf 'package %{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' ${G4_TRIGGER_PACKAGES[*]}
rpm -q --qf '[file %{FILEDIGESTS} %{FILENAMES}\n]' ${G4_PACKAGES_KEYED_BY_FILE_DIGEST[*]} | awk 'NF == 3'
find ${G4_TRIGGER_DIRS[*]} -type f -exec sha256sum {} + | awk '{ print "file", \$1, \$2 }'
sha256sum ${overlay_files[*]} | awk '{ print "file", \$1, \$2 }'
EOF
}

g4_key_of_image() {
    local image=$1
    as_root podman run --rm -i --net=none --entrypoint /bin/sh "$image" -s < <(g4_key_script) | LC_ALL=C sort -u
}

g4_key_of_guest() { vm_ssh sh -s < <(g4_key_script) | LC_ALL=C sort -u; }

g4_key_lines() {
    local file=$1
    grep -E '^(package|file) ' "$file" | LC_ALL=C sort -u
}

record_g4_pass() {
    local test=$1-g4 image=$2 partial key image_id
    [[ $QUALIFY_LAYOUT == separate-boot ]] ||
        fail "$test" "QUALIFY_LAYOUT=$QUALIFY_LAYOUT skipped the counted rollback: no G4 pass is recorded"
    partial=$(awk -F' [|] ' '$2 == "SKIP" || $2 == "WARN" { sub(/^[|] /, "", $1); print $1 }' \
        "$QUALIFY_OUT/results.md" | paste -sd' ' -)
    [[ -z $partial ]] || fail "$test" "SKIP or WARN rows ($partial): no G4 pass is recorded"
    key=$(g4_key_of_guest) || fail "$test" "cannot compute the G4 key in the guest"
    [[ -n $key ]] || fail "$test" "the guest's G4 key is empty"
    image_id=$(as_root podman image inspect --format '{{.Id}}' "$image") || fail "$test" "cannot read the ID of $image"
    mkdir -p "$(dirname "$QUALIFY_G4_RECORD")"
    {
        printf '%s\n' "$key"
        printf 'passed-at %s\n' "$(date -u +%FT%TZ)"
        printf 'image-id %s\n' "$image_id"
    } >"$QUALIFY_G4_RECORD.tmp"
    mv -f "$QUALIFY_G4_RECORD.tmp" "$QUALIFY_G4_RECORD"
    result "$test" PASS "recorded the G4 key ($(grep -c '^package ' <<<"$key") packages, $(grep -c '^file ' <<<"$key") files) of image $image_id in $QUALIFY_G4_RECORD"
}

cmd_fresh() {
    (($# == 1)) || die "usage: qualify.sh fresh CANDIDATE"
    local candidate digest
    candidate=$(candidate_ref "$1")
    digest=$(digest_of "$candidate")
    ensure_key
    install_disk fresh "$candidate" "$(channel_of "$candidate")"
    start_vm fresh
    wait_ssh
    assert_green fresh-install "$digest"
    assert_bootloader_updated fresh-install
    save_bootc_status_fixture booted
    negative_tests "$candidate"
    download_only_test "$candidate"
    save_journal final
    stop_vm
    drop_disk fresh
}

cmd_upgrade() {
    (($# == 2)) || die "usage: qualify.sh upgrade FROM CANDIDATE"
    local from candidate from_digest digest status
    from=$(candidate_ref "$1")
    candidate=$(candidate_ref "$2")
    from_digest=$(digest_of "$from")
    digest=$(digest_of "$candidate")
    [[ $from_digest != "$digest" ]] || die "upgrade: FROM and CANDIDATE are the same image"
    ensure_key
    install_disk upgrade "$from" "$(channel_of "$from")"
    start_vm upgrade
    wait_ssh
    assert_green upgrade-baseline "$from_digest"

    stage_candidate upgrade-stage "$candidate"
    local grubstate=disarmed
    if vm_ssh 'command -v apexctl' >/dev/null 2>&1; then
        apply_candidate upgrade-apply "$digest" staged-applied
        grubstate=confirmed
    else
        vm_ssh 'bootc upgrade --from-downloaded' || fail upgrade-apply "bootc upgrade --from-downloaded failed"
        result upgrade-apply WARN "$from has no apexctl; unlocked with bootc, boot counter not armed"
    fi

    vm_reboot
    assert_green upgrade-reboot "$digest" "$grubstate"
    assert_bootloader_updated upgrade-reboot
    status=$(status_json)
    [[ $(jq -r '.status.rollback.image.imageDigest // empty' <<<"$status") == "$from_digest" ]] ||
        fail upgrade-reboot "rollback deployment is not the previous image $from_digest"
    save_bootc_status_fixture upgraded
    save_journal final
    stop_vm
    drop_disk upgrade
}

cmd_red() {
    (($# == 2)) || die "usage: qualify.sh red FROM CANDIDATE"
    local from candidate from_digest digest
    from=$(candidate_ref "$1")
    candidate=$(candidate_ref "$2")
    from_digest=$(digest_of "$from")
    digest=$(digest_of "$candidate")
    [[ $from_digest != "$digest" ]] ||
        die "red: FROM and CANDIDATE are the same image; Apply arms only when a different image is staged"
    if [[ $QUALIFY_LAYOUT != separate-boot ]]; then
        result red SKIP "QUALIFY_LAYOUT=$QUALIFY_LAYOUT: GRUB cannot save the counter on a btrfs /boot"
        notice "counted-rollback test skipped for QUALIFY_LAYOUT=$QUALIFY_LAYOUT"
        return 0
    fi
    ensure_key
    install_disk red "$from" "$(channel_of "$from")"
    start_vm red
    wait_ssh
    assert_green red-baseline "$from_digest"
    if ! vm_ssh 'command -v apexctl' >/dev/null 2>&1; then
        result red SKIP "$from has no apexctl, so nothing can arm the boot counter"
        stop_vm
        drop_disk red
        return 0
    fi

    stage_candidate red-stage "$candidate"
    counted_rollback red "$from_digest" "$digest"
    save_journal final
    stop_vm
    drop_disk red
}

cmd_local() {
    (($# == 1)) || die "usage: qualify.sh local localhost/NAME:TAG"
    local image=$1 digest
    [[ $image =~ ^localhost/[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] ||
        die "expected a local image reference localhost/NAME[:TAG], got '$image'"
    digest=$(as_root podman image inspect --format '{{.Digest}}' "$image") ||
        die "$image is not in local container storage (build it with image.sh build)"
    ensure_key
    install_disk local "$image" "$APEX_REPO_TESTING:$APEX_FEDORA"
    start_vm local
    wait_ssh
    assert_green local-install "$digest"
    assert_bootloader_updated local-install
    save_bootc_status_fixture booted
    vm_ssh 'command -v apexctl' >/dev/null || fail local-install "$image has no apexctl, so nothing can arm the boot counter"

    if [[ $QUALIFY_LAYOUT == separate-boot ]]; then
        stage_local_candidate local-stage "$digest"
        counted_rollback local "$digest" "$LOCAL_CANDIDATE_DIGEST"
    else
        result local-red SKIP "QUALIFY_LAYOUT=$QUALIFY_LAYOUT: GRUB cannot save the counter on a btrfs /boot"
        create_test_user local
        vm_reboot
        assert_green local-rebooted "$digest"
        assert_greeter local
    fi

    set_test_password local
    vm_reboot
    assert_green local-login-boot "$digest"
    assert_bootloader_updated local-login-boot
    greeter_login local
    login_lock_unlock local
    crash_guard_logins local
    record_g4_pass local "$image"
    save_journal final
    stop_vm
    drop_disk local
}

cmd_g4_key() {
    (($# == 1)) || die "usage: qualify.sh g4-key localhost/NAME:TAG"
    local image=$1 key
    key=$(g4_key_of_image "$image") || die "cannot compute the G4 key of $image"
    [[ -n $key ]] || die "the G4 key of $image is empty"
    printf '%s\n' "$key"
}

cmd_g4_due() {
    (($# == 1)) || die "usage: qualify.sh g4-due KEY"
    local key_file=$1 now recorded passed_at passed_epoch image_id age_days
    [[ -s $key_file ]] || die "no G4 key in $key_file (qualify.sh g4-key writes one)"
    now=$(g4_key_lines "$key_file")
    [[ -n $now ]] || die "no G4 key in $key_file (qualify.sh g4-key writes one)"
    if [[ ! -s $QUALIFY_G4_RECORD ]]; then
        log "G4 is due: no local pass is recorded in $QUALIFY_G4_RECORD"
        return 0
    fi
    recorded=$(g4_key_lines "$QUALIFY_G4_RECORD")
    if [[ $now != "$recorded" ]]; then
        log "G4 is due; new since the last pass:" \
            "$(LC_ALL=C comm -13 <(printf '%s\n' "$recorded") <(printf '%s\n' "$now") | head -n 5 | paste -sd ';' -)" \
            "(gone: $(LC_ALL=C comm -23 <(printf '%s\n' "$recorded") <(printf '%s\n' "$now") | wc -l) line(s))"
        return 0
    fi
    passed_at=$(sed -n 's/^passed-at //p' "$QUALIFY_G4_RECORD")
    image_id=$(sed -n 's/^image-id //p' "$QUALIFY_G4_RECORD")
    if ! passed_epoch=$(date -u -d "$passed_at" +%s 2>/dev/null) || [[ -z $passed_at ]]; then
        log "G4 is due: the last pass in $QUALIFY_G4_RECORD records no time"
        return 0
    fi
    age_days=$((($(date -u +%s) - passed_epoch) / 86400))
    if ((age_days >= G4_MAX_AGE_DAYS)); then
        log "G4 is due: this key passed on $passed_at, $age_days days ago (G4 runs at least every $G4_MAX_AGE_DAYS days)"
        return 0
    fi
    log "G4 is not due: this key passed on $passed_at for image ${image_id:-unknown} ($QUALIFY_G4_RECORD)"
    printf 'passed-at %s\nimage-id %s\n' "$passed_at" "${image_id:-unknown}"
    return "$G4_NOT_DUE"
}

cmd_all() {
    (($# == 1)) || die "usage: qualify.sh all CANDIDATE"
    local candidate stable rc=0
    candidate=$(candidate_ref "$1")
    cmd_fresh "$candidate"
    stable=$(registry_digest "$APEX_REPO_STABLE:$APEX_FEDORA") || rc=$?
    case $rc in
        0)
            if [[ $stable == "$(digest_of "$candidate")" ]]; then
                result upgrade SKIP "the candidate already is apex:$APEX_FEDORA"
                result red SKIP "the candidate already is apex:$APEX_FEDORA; the counted rollback needs another image to fall back to"
            else
                cmd_upgrade "$APEX_REPO_STABLE@$stable" "$candidate"
                cmd_red "$APEX_REPO_STABLE@$stable" "$candidate"
            fi
            ;;
        "$REGISTRY_ABSENT")
            result upgrade SKIP "apex:$APEX_FEDORA does not exist yet (first promotion)"
            result red SKIP "apex:$APEX_FEDORA does not exist yet: no previous image to fall back to"
            notice "upgrade and counted-rollback tests skipped: $APEX_REPO_STABLE:$APEX_FEDORA does not exist yet"
            ;;
        *) fail upgrade "cannot resolve $APEX_REPO_STABLE:$APEX_FEDORA" ;;
    esac
}

cmd_host_setup() {
    in_github_actions || die "host-setup changes the host; in the builder VM install qemu-system-x86, edk2-ovmf, dosfstools, btrfs-progs and openssh-clients yourself"
    "$APEX_ROOT/.github/scripts/ci-host.sh" kvm
    retry 3 10 sudo apt-get update -qq
    retry 3 10 sudo apt-get install -y -qq --no-install-recommends \
        qemu-system-x86 qemu-utils ovmf dosfstools btrfs-progs openssh-client jq
    "$APEX_ROOT/.github/scripts/ci-host.sh" podman-conf
}

cleanup() {
    local rc=$?
    if ((rc != 0)) && vm_alive; then save_journal failure; fi
    stop_vm || true
    unmount_all
    local l
    for l in "${LOOPS[@]}"; do as_root losetup --detach "$l" 2>/dev/null || true; done
    if [[ ${QUALIFY_KEEP_DISKS:-0} != 1 ]]; then rm -f "$QUALIFY_OUT"/*.raw; fi
    publish_results
    exit "$rc"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        host-setup) cmd_host_setup; return ;;
        g4-key) cmd_g4_key "$@"; return ;;
        g4-due) cmd_g4_due "$@"; return ;;
        fresh | upgrade | red | all | local) ;;
        *) usage ;;
    esac
    require qemu-system-x86_64 ssh ssh-keygen jq openssl skopeo podman truncate sfdisk \
        losetup mkfs.vfat mkfs.ext4 mkfs.btrfs comm
    mkdir -p "$QUALIFY_OUT"
    rm -rf "$QUALIFY_OUT/logs.previous"
    if [[ -d $QUALIFY_OUT/logs ]]; then mv "$QUALIFY_OUT/logs" "$QUALIFY_OUT/logs.previous"; fi
    mkdir -p "$QUALIFY_OUT/logs" "$QUALIFY_OUT/fixtures"
    : >"$QUALIFY_OUT/results.md"
    trap cleanup EXIT
    "cmd_$cmd" "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
