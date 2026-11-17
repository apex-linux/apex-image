#!/bin/bash
# Builds the OS image into local container storage.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

main() {
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"

  # Build temporary files stay off /tmp, which is memory-backed.
  mkdir -p "${APEX_CACHE}/tmp"
  export TMPDIR="${APEX_CACHE}/tmp"

  # The build is mostly single-threaded dnf, so a low priority and a
  # memory cap bound its load instead of a CPU limit.
  nice -n 10 ionice -c 3 podman build \
    --pull=newer \
    --memory=4g \
    --tag "${APEX_IMAGE}" \
    .
  podman images "${APEX_IMAGE}"
}

main "$@"
