#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Qualify an Apex image in a KVM guest with OVMF: a real `bootc install`, GRUB, the Apex
# boot counter and boot assessment, signature enforcement and the upgrade path, all on
# the digest that will be published.
#
#   qualify.sh host-setup              for a CI runner, if one is ever used: /dev/kvm
#                                      access, QEMU, OVMF
#   qualify.sh fresh CANDIDATE         install CANDIDATE, boot, assert, negative
#                                      signature tests, reboot with a download-only stage
#   qualify.sh upgrade FROM CANDIDATE  install FROM (e.g. the current stable), stage
#                                      CANDIDATE by digest, apply it with FROM's apexctl
#                                      (arms the boot counter), reboot, assert green and
#                                      confirmed
#   qualify.sh red FROM CANDIDATE      the counted rollback: install FROM, stage
#                                      CANDIDATE, write CANDIDATE's digest to the hook
#                                      /var/lib/apex/force-red, apply, then boot without
#                                      ever logging in: CANDIDATE must fail its assessment
#                                      and reboot itself 3 times, GRUB must fall back to
#                                      FROM, and FROM must roll back (bootc rollback),
#                                      denylist CANDIDATE and leave grubenv disarmed
#   qualify.sh all CANDIDATE           fresh, then upgrade and red from apex:45 when it
#                                      exists and differs from CANDIDATE
#   qualify.sh local IMAGE             smoke test of an unpublished image in local
#                                      container storage (localhost/NAME:TAG, e.g.
#                                      image.sh's localhost/apex:build): install, boot and
#                                      assert green like `fresh`, without the signature
#                                      tests (a local image carries no signature)
#
# CANDIDATE and FROM are REPO@sha256:... references (a bare sha256:... means
# ghcr.io/sekirokenjii/apex-testing@sha256:...). It needs nested KVM, and sudo for
# podman, losetup and mount. `red` works with any two different Apex images whose updater
# arms the counter, e.g. `qualify.sh red sha256:<older> sha256:<newer>`.
#
# Environment (all optional):
#   QUALIFY_OUT           work directory (default _build/qualify); fixtures/ and logs/
#                         in it are the artifacts worth keeping
#   QUALIFY_LAYOUT        separate-boot (default): ESP + ext4 /boot + btrfs root, the
#                         laptop's layout, installed with `bootc install to-filesystem`;
#                         to-disk: `bootc install to-disk --via-loopback --filesystem btrfs`
#                         (`red` is skipped there: GRUB cannot count on a btrfs /boot)
#   QUALIFY_DISK_GB (40)  QUALIFY_MEM (6G)  QUALIFY_SMP (4)  QUALIFY_SSH_PORT (2222)
#   QUALIFY_BOOT_TIMEOUT  seconds to wait for SSH after a boot (default 900)
#   QUALIFY_ATTEMPT_TIMEOUT  seconds an armed, failing boot may take until it has
#                         rebooted itself (default QUALIFY_BOOT_TIMEOUT + 300)
#   QUALIFY_POLL          seconds between checks while waiting for QEMU (default 5)
#   QUALIFY_KEEP_DISKS    1 keeps the VM disks after each scenario
#   OVMF_CODE, OVMF_VARS, OVMF_FORMAT  firmware files (auto-detected on Ubuntu, Fedora)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

readonly STRICT_POLICY=/usr/share/apex/containers/policy.json
readonly GRUBENV=/boot/grub2/grubenv
readonly GUEST_TMP=/var/tmp/apex-qualify
readonly ALLOWED_FAILURES="$APEX_ROOT/.github/scripts/qualify-allowed-failures.txt"
readonly APEX_STATE=/var/lib/apex
# Must match crate apex-boot: checks::force_red::FORCE_RED_PATH, checks::names::FORCED_RED.
readonly FORCE_RED=$APEX_STATE/force-red
readonly FORCED_RED_CHECK=forced-red

VM_NAME=
VM_SERIAL=
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

# start_vm NAME [LOG [QEMU_ARG...]]: QEMU truncates the console log, so a boot whose log
# must survive the next start needs its own LOG.
start_vm() {
    local name=$1 log=${2:-$1}
    shift "$(($# < 2 ? $# : 2))"
    local disk="$QUALIFY_OUT/$name.raw" vars="$QUALIFY_OUT/$name.vars"
    find_ovmf
    [[ -f $vars ]] || cp "$OVMF_VARS" "$vars"
    require_kvm
    VM_NAME=$name
    VM_SERIAL="$QUALIFY_OUT/logs/$log.serial.log"
    rm -f "$QUALIFY_OUT/$name.pid"
    qemu-system-x86_64 -name "apex-$name" -machine q35,accel=kvm -cpu host \
        -m "$QUALIFY_MEM" -smp "$QUALIFY_SMP" \
        -drive "if=pflash,format=$OVMF_FORMAT,unit=0,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=$OVMF_FORMAT,unit=1,file=$vars" \
        -drive "file=$disk,format=raw,if=virtio,cache=writeback,discard=unmap" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$QUALIFY_SSH_PORT-:22" \
        -device virtio-net-pci,netdev=net0 -device virtio-rng-pci \
        -device virtio-vga -display none \
        -serial "file:$VM_SERIAL" -monitor none \
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

assert_running() {
    local test=$1 state failed unexpected
    state=$(vm_ssh 'timeout 900 systemctl is-system-running --wait' 2>/dev/null || true)
    case $state in
        running) ;;
        degraded)
            failed=$(vm_ssh 'systemctl list-units --state=failed --plain --no-legend --no-pager' |
                awk '{print $1}' | sort)
            unexpected=$(comm -23 <(printf '%s\n' "$failed" | sed '/^$/d') \
                <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_FAILURES" | sed '/^$/d' | sort))
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

    local apexctl
    apexctl=$(vm_ssh 'apexctl status --json') || fail "$test" "apexctl status --json failed"
    jq -e 'type == "object"' <<<"$apexctl" >/dev/null || fail "$test" "apexctl status --json is not a JSON object"
    printf '%s\n' "$apexctl" >"$QUALIFY_OUT/fixtures/apexctl-status-$test.json"

    result "$test" PASS "running, apex-boot-assess green, grubenv $grubstate, booted $expected"
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
    local digest=$1 mode
    is_digest "$digest" || die "set_force_red: invalid digest '$digest'"
    local hook_size=$((${#digest} + 1))
    vm_ssh "install -d -m 0700 $APEX_STATE && (umask 077 && printf '%s\n' $digest > $FORCE_RED.tmp) && mv -f $FORCE_RED.tmp $FORCE_RED" ||
        fail red-hook "cannot write $FORCE_RED"
    mode=$(vm_ssh "stat -c '%a %U %s' $FORCE_RED $APEX_STATE" | tr '\n' ' ')
    [[ $mode == "600 root $hook_size 700 root "* ]] || fail red-hook "unexpected mode/owner/size of the hook: $mode"
    result red-hook PASS "$FORCE_RED names $digest"
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

# forced_red_boots N: counts among the N previous boots; prints nothing when the journal
# is not persistent, so that the caller can tell "unknown" from 0.
forced_red_boots() {
    local n=$1 listed count=0 b
    listed=$(vm_ssh 'journalctl --list-boots --no-pager 2>/dev/null' | grep -cE '^[[:space:]]*-?[0-9]+[[:space:]]' || true)
    ((listed > n)) || return 0
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
    set_force_red "$digest"
    apply_candidate red-apply "$digest" red-staged-applied
    save_journal baseline
    # Powered off, not rebooted: the counted boots start under -no-reboot.
    poweroff_vm red-apply

    armed_attempts red "$APEX_BOOT_ATTEMPTS"
    wait_ssh "the VM rebooted a $((APEX_BOOT_ATTEMPTS + 1))th time; GRUB did not fall back to $from_digest after $APEX_BOOT_ATTEMPTS attempts"
    assert_counted_rollback red-fallback "$from_digest" "$digest"
    save_journal fallback

    if vm_ssh 'apexctl update acknowledge --help' >/dev/null 2>&1; then
        vm_ssh 'apexctl update acknowledge' || fail red-acknowledge "apexctl update acknowledge failed"
        ! vm_ssh "test -e $APEX_STATE/health-failure.json" ||
            fail red-acknowledge "$APEX_STATE/health-failure.json is still there after acknowledge"
        result red-acknowledge PASS "apexctl update acknowledge cleared the health failure"
    else
        result red-acknowledge SKIP "$from's apexctl has no 'update acknowledge'"
    fi

    stop_vm
    start_vm red red-settled
    wait_ssh
    assert_green red-settled "$from_digest"
    local status
    status=$(status_json)
    [[ $(jq -r '.status.rollback.image.imageDigest // empty' <<<"$status") == "$digest" ]] ||
        fail red-settled "the failed target $digest is no longer the rollback deployment"
    vm_ssh "rm -f $FORCE_RED" || true
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
    save_bootc_status_fixture booted
    save_journal final
    stop_vm
    drop_disk local
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
        fresh | upgrade | red | all | local) ;;
        *) usage ;;
    esac
    require qemu-system-x86_64 ssh ssh-keygen jq openssl skopeo podman truncate sfdisk \
        losetup mkfs.vfat mkfs.ext4 mkfs.btrfs comm
    mkdir -p "$QUALIFY_OUT/logs" "$QUALIFY_OUT/fixtures"
    : >"$QUALIFY_OUT/results.md"
    trap cleanup EXIT
    "cmd_$cmd" "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
