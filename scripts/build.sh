#!/bin/bash
# Builds the OS image into local container storage as localhost/apex:main.
# Components come from the tip of their main branch, or from the commits
# pinned in a release sync file.
# Usage: build.sh [sync-file]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Compiling stages use half the CPUs; CI, which has the machine to itself,
# sets APEX_BUILD_CPUS. APEX_BUILD_JOBS stages build at once.
readonly CPUS="${APEX_BUILD_CPUS:-$(($(nproc) / 2))}"
readonly JOBS="${APEX_BUILD_JOBS:-1}"

# Prints a short hash of files, or "none" when there are none.
hash_files() {
  if (($# == 0)) || [[ ! -e "$1" ]]; then
    echo none
    return
  fi
  cat "$@" | sha256sum | cut -c 1-16
}

main() {
  local image="${APEX_IMAGE}"
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"

  # Build temporary files stay off /tmp, which is memory-backed.
  mkdir -p "${APEX_CACHE}/tmp"
  export TMPDIR="${APEX_CACHE}/tmp"

  local components
  components="$("$(dirname "$0")/components.sh" \
    "${APEX_BUILD_DIR}/components" "${1:-}")"
  echo "${components}"

  # The patch series: a change rebuilds the layers that depend on it.
  local patches
  patches="${APEX_BUILD_DIR}/components/apex-hardware/patches/libfprint"
  patches="$(hash_files "${patches}"/*)"

  # Most of the build is single-threaded dnf, so a low priority and a
  # memory cap bound its load; compiling stages get CPUS.
  nice -n 10 ionice -c 3 podman build \
    --pull=newer \
    --memory=4g \
    --jobs="${JOBS}" \
    --target apex \
    --build-arg "CPUS=${CPUS}" \
    --build-arg "COMPONENTS=${components//$'\n'/ }" \
    --build-arg "LIBFPRINT_PATCHES=${patches}" \
    --tag "${image}" \
    .
  podman images "${image}"
}

main "$@"
