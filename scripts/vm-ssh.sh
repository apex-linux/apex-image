#!/bin/bash
# Runs a command as root in the virtual machine that `just vm-disk` booted,
# or opens a shell. Usage: vm-ssh.sh [command...]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

main() {
  # The test VM gets a new host key on every install, so do not record it.
  exec ssh -i "${APEX_BUILD_DIR}/vm-disk/id_ed25519" -p 2222 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR root@127.0.0.1 "$@"
}

main "$@"
