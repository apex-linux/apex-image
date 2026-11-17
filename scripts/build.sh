#!/bin/bash
# Builds the OS image into local container storage, with each component at
# the tip of its main branch, or at the commits pinned in a release sync file.
# Usage: build.sh [sync-file]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

main() {
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"

  # Build temporary files stay off /tmp, which is memory-backed.
  mkdir -p "${APEX_CACHE}/tmp"
  export TMPDIR="${APEX_CACHE}/tmp"

  local components
  components="$("$(dirname "$0")/components.sh" \
    "${APEX_BUILD_DIR}/components" "${1:-}")"
  echo "${components}"

  # The build is mostly single-threaded dnf, so a low priority and a
  # memory cap bound its load instead of a CPU limit.
  nice -n 10 ionice -c 3 podman build \
    --pull=newer \
    --memory=4g \
    --build-arg "COMPONENTS=${components//$'\n'/ }" \
    --tag "${APEX_IMAGE}" \
    .
  podman images "${APEX_IMAGE}"
}

main "$@"
