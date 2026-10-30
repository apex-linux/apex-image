#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# W17, a throwaway spike, never merged: can a standard hosted runner boot a bootc install
# with qualify.sh's QEMU? Stock fedora-bootc has no apexctl, so qualify.sh local refuses it.
set -euo pipefail

readonly IMAGE=quay.io/fedora/fedora-bootc:45 BOOTS=${1:-3}
SPIKE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# Stock fedora-bootc also installs BIOS GRUB, which separate-boot's table has no partition for.
export QUALIFY_OUT=${RUNNER_TEMP:-/tmp}/kvm-spike QUALIFY_MEM=3G QUALIFY_SMP=4 QUALIFY_LAYOUT=to-disk
# shellcheck source=SCRIPTDIR/../scripts/qualify.sh
. "$SPIKE_ROOT/.github/scripts/qualify.sh"

DF_PEAK_FILE=$QUALIFY_OUT/df-peak
df_used() { df -B1M --output=used / | tail -n 1 | tr -d ' '; }
sample_df() {
    local peak=0 used
    while :; do
        used=$(df_used)
        ((used <= peak)) || { peak=$used; echo "$peak" >"$DF_PEAK_FILE"; }
        sleep 5
    done
}
minutes() { awk -v s="$1" 'BEGIN { printf "%.1f", s / 60 }'; }

mkdir -p "$QUALIFY_OUT/logs"
trap 'stop_vm || true; unmount_all; kill "$sampler" 2>/dev/null || true' EXIT
df_start=$(df_used)
sample_df &
sampler=$!
kvm=no
[[ -w /dev/kvm ]] && kvm=yes
summary "### W17: hosted KVM spike ($IMAGE, $QUALIFY_LAYOUT, ${QUALIFY_MEM}, ${QUALIFY_SMP} vCPUs, accel=kvm, vmport=off, -cpu host)" "" \
    "/dev/kvm writable: $kvm; df / used at start: ${df_start} MiB" "" \
    "| Boot | Install min | Boot to ssh min | Kernel | is-system-running | Result |" "|---|---|---|---|---|---|"
ensure_key
passed=0
for ((n = 1; n <= BOOTS; n++)); do
    t0=$SECONDS
    result=FAIL kernel=- state=- boot=-
    install_disk spike "$IMAGE" "$IMAGE"
    install=$(minutes $((SECONDS - t0)))
    t1=$SECONDS
    start_vm spike "spike-$n"
    if (wait_ssh); then
        boot=$(minutes $((SECONDS - t1)))
        kernel=$(vm_ssh uname -r 2>/dev/null) || kernel=-
        state=$(vm_ssh 'timeout 300 systemctl is-system-running --wait' 2>/dev/null) || true
        result=PASS
        passed=$((passed + 1))
    fi
    stop_vm
    drop_disk spike
    rm -f "$QUALIFY_OUT/spike.vars"
    summary "| $n | $install | $boot | $kernel | ${state:--} | $result |"
done
summary "" "Boots that reached ssh: $passed of $BOOTS. df / used, peak: $(cat "$DF_PEAK_FILE" 2>/dev/null || echo "$df_start") MiB."
((passed == BOOTS))
