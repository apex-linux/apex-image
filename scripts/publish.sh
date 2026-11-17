#!/bin/bash
# Pushes the built image to the rolling tag on GitHub Container Registry.
# CI runs it on pushes to main, after logging in to the registry.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly REMOTE="${APEX_REMOTE:-ghcr.io/apex-linux/apex:main}"

main() {
  podman push "${APEX_IMAGE}" "docker://${REMOTE}"
  echo "Published ${REMOTE}"
}

main "$@"
