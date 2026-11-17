#!/bin/bash
# Refuses heavy work when the machine is short of disk or memory, and shows
# what Apex itself can clean.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly MIN_DISK_GB="${APEX_MIN_DISK_GB:-25}"
readonly MIN_MEM_GB="${APEX_MIN_MEM_GB:-4}"

# Prints the free space in GiB of the file system that holds a path.
free_gb() {
  df --output=avail --block-size=1G "$1" | tail -n 1 | tr -d ' '
}

report_cleanable() {
  echo "Apex can free (just clean):"
  podman images --filter "label=${APEX_LABEL}" \
    --format '  image {{.Repository}}:{{.Tag}} {{.Size}}'
  local dir
  for dir in "${APEX_BUILD_DIR}" "${APEX_CACHE}"; do
    if [[ -d "${dir}" ]]; then
      echo "  $(du -sh "${dir}" | cut -f 1) ${dir}"
    fi
  done
}

main() {
  mkdir -p "${APEX_CACHE}"
  local status=0
  local storage
  storage="$(podman info --format '{{.Store.GraphRoot}}')"

  local path free
  for path in "${APEX_CACHE}" "${storage}" "${PWD}"; do
    free="$(free_gb "${path}")"
    echo "Disk: ${free} GiB free for ${path}"
    if ((free < MIN_DISK_GB)); then
      apex::err "doctor: ${path} has ${free} GiB free; need ${MIN_DISK_GB}."
      status=1
    fi
  done

  local mem_mb
  mem_mb="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)"
  echo "Memory: ${mem_mb} MiB available"
  if ((mem_mb < MIN_MEM_GB * 1024)); then
    apex::err "doctor: ${mem_mb} MiB memory available; need ${MIN_MEM_GB} GiB."
    status=1
  fi

  report_cleanable
  if ((status != 0)); then
    apex::err "doctor: not enough room for heavy work. Run 'just clean'," \
      "or free space elsewhere yourself."
  fi
  exit "${status}"
}

main "$@"
