#!/bin/bash
# Starts the other system from Apex's boot menu, as a person would: reboots
# the VM that `just vm-disk` started, waits for the GRUB menu on the serial
# console, checks that it stays up for 5 seconds and lists "Ubuntu", picks
# its last entry (the other systems come last) and checks that the other
# system's test loader prints its marker. That loader then powers the VM
# off. Needs a test loader under EFI/ubuntu, as image/iso/dualboot-disk.sh
# makes.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly MARKER="APEX-TEST-OTHER-LOADER-OK"

vm_dir=""
serial=""
start=0

# Presses one key in the VM, through QEMU's monitor socket.
press() {
  python3 - "${vm_dir}/qmp.sock" "$1" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.connect(sys.argv[1])
stream = sock.makefile("rw")
stream.readline()
for command in (
    {"execute": "qmp_capabilities"},
    {"execute": "send-key",
     "arguments": {"keys": [{"type": "qcode", "data": sys.argv[2]}]}},
):
    stream.write(json.dumps(command) + "\n")
    stream.flush()
    stream.readline()
PY
}

# Waits until the serial console, since the reboot, shows a line matching
# the given Perl regular expression.
wait_for() {
  local pattern="$1" what="$2" i
  for ((i = 0; i < 240; i++)); do
    if tail -c "+${start}" "${serial}" | grep -aqP -- "${pattern}"; then
      echo "${what}"
      return 0
    fi
    sleep 0.5
  done
  apex::err "vm-grub-other: ${what}: not seen (waited for /${pattern}/)"
  exit 1
}

main() {
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-disk")"
  serial="${vm_dir}/serial.log"
  start=$(($(stat -c %s "${serial}") + 1))
  "$(dirname "$0")/vm-ssh.sh" systemctl reboot || true
  wait_for "automatically in 5s" "The boot menu stays up for 5 seconds"
  # The firmware also says "Ubuntu distribution of EDK II", later.
  wait_for "Ubuntu(?! distribution)" "The boot menu lists Ubuntu"
  press end
  press ret
  wait_for "${MARKER}" "Its last entry started the other system's loader"
}

main "$@"
