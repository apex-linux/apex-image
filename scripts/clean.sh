#!/bin/bash
# Removes the images, disks and caches that Apex itself created, and nothing
# that belongs to another project.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

main() {
  apex::lock_heavy

  apex::prune_untagged
  local -a images
  mapfile -t images < <(podman images --quiet --filter "label=${APEX_LABEL}" \
    | sort -u)
  if ((${#images[@]} > 0)); then
    echo "Removing ${#images[@]} Apex image(s)"
    podman rmi --force "${images[@]}"
  fi

  echo "Removing ${APEX_BUILD_DIR}/ and ${APEX_CACHE}/"
  rm -rf "${APEX_BUILD_DIR}"
  # Keep the lock file: another shell may be waiting on it.
  find "${APEX_CACHE}" -mindepth 1 -maxdepth 1 ! -name heavy.lock \
    -exec rm -rf {} +
}

main "$@"
