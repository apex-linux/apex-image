#!/bin/bash
# Pushes the built image to the rolling tag on GitHub Container Registry.
# CI runs it on pushes to main, after logging in to the registry.
# Usage: publish.sh [flavor]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly REMOTE="${APEX_REMOTE:-ghcr.io/apex-linux/apex:main}"

main() {
  local suffix="${1:+-$1}"
  podman push "${APEX_IMAGE}${suffix}" "docker://${REMOTE}${suffix}"
  echo "Published ${REMOTE}${suffix}"
}

main "$@"
