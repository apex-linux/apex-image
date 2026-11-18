#!/bin/bash
# Boots the disk in build/vm-disk for the first time, runs the checks of
# scripts/vm-checks.sh on it and powers it off. The checks decide the exit
# status.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

main() {
  apex::lock_heavy
  local vm_dir
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-disk")"
  "$(dirname "$0")/vm-disk.sh" >"${vm_dir}/vm-disk.log" 2>&1 &
  local vm_pid=$! i
  for ((i = 0; i < 100; i++)); do
    "$(dirname "$0")/vm-ssh.sh" -o ConnectTimeout=3 true 2>/dev/null && break
    kill -0 "${vm_pid}" 2>/dev/null || break
    sleep 3
  done

  local status=0
  "$(dirname "$0")/vm-checks.sh" || status=$?
  "$(dirname "$0")/vm-ssh.sh" systemctl poweroff 2>/dev/null || true
  wait "${vm_pid}" || true
  return "${status}"
}

main "$@"
