#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A throwaway spike, never merged: local-diag's snapshot functions on a real KVM guest. It
# saves after boot, changes the guest, loads, and checks the disk, the clock and a restart.
set -euo pipefail

readonly IMAGE=${SPIKE_IMAGE:-registry.fedoraproject.org/fedora-bootc:45}
SPIKE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export QUALIFY_OUT=${RUNNER_TEMP:-/tmp}/snapshot-spike QUALIFY_MEM=${SPIKE_MEM:-6G} QUALIFY_SMP=4 QUALIFY_LAYOUT=to-disk
# shellcheck source=SCRIPTDIR/../scripts/qualify.sh
. "$SPIKE_ROOT/.github/scripts/qualify.sh"

seconds_of() { # LABEL COMMAND...: run it, add its seconds to the summary table
    local label=$1 t0=$SECONDS
    shift
    "$@"
    summary "| $label | $((SECONDS - t0)) |"
}
check() { # WHAT COMMAND...: a line in the summary, and the spike fails with it
    if "${@:2}"; then summary "- ok: $1"; else summary "- FAILED: $1"; FAILED=1; fi
}
FAILED=0

mkdir -p "$QUALIFY_OUT/logs"
: >"$QUALIFY_OUT/results.md"
trap 'stop_vm || true; unmount_all; [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || cat "$GITHUB_STEP_SUMMARY"' EXIT
ensure_key
podman_pull "$IMAGE"
summary "### Snapshot spike: $IMAGE, $QUALIFY_LAYOUT, $QUALIFY_MEM, $QUALIFY_SMP vCPUs" "" "| Step | Seconds |" "|---|---|"

DIAG=1
seconds_of "install" install_disk local "$IMAGE" "$IMAGE"
start_vm local
seconds_of "boot to ssh" wait_ssh
vm_ssh 'timeout 600 systemctl is-system-running --wait' >/dev/null || true
vm_ssh 'echo saved >/var/tmp/spike-marker'
diag_save_state
seconds_of "savevm (diag_snapshot_save)" diag_snapshot_save spike-save
used=$(vm_ssh "free -m | awk '/^Mem:/ { print \$3 }'")

vm_ssh 'echo changed >/var/tmp/spike-marker; touch /var/tmp/spike-after-save; sync'
sleep 75
t0=$SECONDS
hmp "loadvm $DIAG_SNAPSHOT" 600 >"$QUALIFY_OUT/logs/loadvm.out"
until vm_answers; do sleep 1; done
summary "| loadvm to ssh | $((SECONDS - t0)) |"
skew=$(diag_skew)
seconds_of "clock check (diag_clock)" diag_clock spike-clock
after=$(diag_skew)
marker=$(vm_ssh 'cat /var/tmp/spike-marker')
check "the disk is back to the save: the marker reads '$marker'" test "$marker" = saved
check "a file made after the save is gone" vm_ssh '! test -e /var/tmp/spike-after-save'
check "loadvm printed nothing: '$(cat "$QUALIFY_OUT/logs/loadvm.out")'" test ! -s "$QUALIFY_OUT/logs/loadvm.out"
check "the loaded guest's clock was ${skew} s off the host's, then ${after} s" \
    awk -v s="$after" 'BEGIN { exit !(s >= -1 && s <= 1) }'

vm_ssh 'echo changed-again >/var/tmp/spike-marker'
seconds_of "a second load (diag_snapshot_load)" diag_snapshot_load spike-load-2
check "a second load is back to the save too" test "$(vm_ssh 'cat /var/tmp/spike-marker')" = saved

kill -9 "$(cat "$QUALIFY_OUT/local.pid")"
wait_vm_exit 30 || true
seconds_of "QEMU killed: -loadvm restart (diag_snapshot_load)" diag_snapshot_load spike-recover
check "a QEMU started with -loadvm is back to the save" test "$(vm_ssh 'cat /var/tmp/spike-marker')" = saved

stop_vm
summary "" "- RAM in use at the save: ${used} MiB" \
    "- overlay sizes: $(du -h "$QUALIFY_OUT/local.raw.qcow2" "$QUALIFY_OUT/local.vars.qcow2" | awk '{ printf "%s %s; ", $2, $1 }')"
seconds_of "fold the overlay back and read the journal (save_disk_journal)" save_disk_journal local
check "the disk journal has the run's last boot" grep -q . "$QUALIFY_OUT/logs/local.disk-journal.txt"
check "and the overlays are gone" test ! -e "$QUALIFY_OUT/local.raw.qcow2"
cp "$QUALIFY_OUT/results.md" "$QUALIFY_OUT/logs/"
exit "$FAILED"
