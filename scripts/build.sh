#!/bin/bash
# Builds the OS image into local container storage as localhost/apex:main,
# or a flavor of it as localhost/apex:main-<flavor>. Components come from the
# tip of their main branch, or from the commits pinned in the sync file that
# APEX_SYNC names (a release's release/sync).
# Usage: build.sh [flavor]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly NEGATIVO17_REPOMD="https://negativo17.org/repos/nvidia/fedora-45/x86_64/repodata/repomd.xml"
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
  local flavor="${1:-}"
  local target="apex" image="${APEX_IMAGE}"
  if [[ -n "${flavor}" ]]; then
    target="apex-${flavor}"
    image="${APEX_IMAGE}-${flavor}"
  fi
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"

  # Build temporary files stay off /tmp, which is memory-backed.
  mkdir -p "${APEX_CACHE}/tmp"
  export TMPDIR="${APEX_CACHE}/tmp"

  local components
  components="$("$(dirname "$0")/components.sh" \
    "${APEX_BUILD_DIR}/components" "${APEX_SYNC:-}")"
  echo "${components}"

  # Values that make the layers depending on them rebuild when they change:
  # the patch series and negativo17's repository metadata.
  local patches nvidia_repo=none
  patches="${APEX_BUILD_DIR}/components/apex-hardware/patches/libfprint"
  patches="$(hash_files "${patches}"/*)"
  if [[ "${flavor}" == "nvidia" ]]; then
    nvidia_repo="$(curl --fail --silent --show-error "${NEGATIVO17_REPOMD}" \
      | sha256sum | cut -c 1-16)"
  fi

  local -a args=(
    --memory=4g
    --jobs="${JOBS}"
    --build-arg "CPUS=${CPUS}"
    --build-arg "COMPONENTS=${components//$'\n'/ }"
    --build-arg "LIBFPRINT_PATCHES=${patches}"
    --build-arg "NVIDIA_REPO=${nvidia_repo}"
  )
  # Most of the build is single-threaded dnf, so a low priority and a
  # memory cap bound its load; compiling stages get CPUS.
  nice -n 10 ionice -c 3 podman build --pull=newer "${args[@]}" \
    --target "${target}" --tag "${image}" .
  podman images "${image}"

  # Keep this build's builder stages as the cache for the next one, by
  # tagging them (every step is cached, so this takes seconds), then remove
  # the untagged Apex images: what this build superseded.
  local stage
  for stage in components libfprint ${flavor:+nvidia-kmod}; do
    podman build --pull=never --quiet "${args[@]}" --target "${stage}" \
      --tag "${APEX_CACHE_IMAGE}:${stage}" . >/dev/null
  done
  apex::prune_untagged
}

main "$@"
