#!/bin/bash
# Shared settings for the recipes in the justfile. Sourced, not run.
# shellcheck disable=SC2034 # The scripts that source this file use these.

readonly APEX_CACHE="${HOME}/.cache/apex"
readonly APEX_BUILD_DIR="build"
readonly APEX_IMAGE="${APEX_IMAGE:-localhost/apex:main}"
# Builder stages kept as the build cache, one tag per stage.
readonly APEX_CACHE_IMAGE="localhost/apex-cache"
# Every image this repository builds carries this label, intermediate layers
# included, so `just clean` can find them without touching other projects.
readonly APEX_LABEL="org.opencontainers.image.source=https://github.com/apex-linux/apex-image"
readonly APEX_VM_MEMORY="4G"
# The UEFI firmware, in Ubuntu's or Fedora's layout.
readonly APEX_OVMF_DIRS="/usr/share/OVMF /usr/share/edk2/ovmf"

apex::err() {
  echo "$*" >&2
}

# Takes the machine-wide lock for heavy work, so that two sessions never
# build or boot at the same time. The lock is released when the shell exits.
# A script that already holds it can call another heavy script.
apex::lock_heavy() {
  if [[ -n "${APEX_HEAVY_LOCKED:-}" ]]; then
    return 0
  fi
  mkdir -p "${APEX_CACHE}"
  exec 9>"${APEX_CACHE}/heavy.lock"
  if ! flock --nonblock 9; then
    apex::err "Another heavy Apex job holds ${APEX_CACHE}/heavy.lock; try later."
    exit 1
  fi
  export APEX_HEAVY_LOCKED=1
}

# Prints the first existing UEFI firmware file among the given names.
apex::ovmf() {
  local dir name
  for dir in ${APEX_OVMF_DIRS}; do
    for name in "$@"; do
      if [[ -f "${dir}/${name}" ]]; then
        echo "${dir}/${name}"
        return 0
      fi
    done
  done
  apex::err "No UEFI firmware ($*) in ${APEX_OVMF_DIRS}; install OVMF."
  exit 1
}

# Runs QEMU with what every Apex virtual machine shares: KVM, 4 GiB of
# memory, half the host's CPUs, a virtio display, and a serial log and QMP
# socket in <vm-dir>. APEX_VM_DISPLAY=none runs it without a window.
# Usage: apex::qemu <vm-dir> [qemu-args...]
apex::qemu() {
  local vm_dir="$1"
  shift
  echo "Serial console: ${vm_dir}/serial.log. QMP: ${vm_dir}/qmp.sock."
  qemu-system-x86_64 \
    -name apex \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "$(($(nproc) / 2))" \
    -m "${APEX_VM_MEMORY}" \
    -device virtio-vga \
    -device qemu-xhci \
    -device usb-tablet \
    -display "${APEX_VM_DISPLAY:-gtk}" \
    -serial "file:${vm_dir}/serial.log" \
    -qmp "unix:${vm_dir}/qmp.sock,server=on,wait=off" \
    "$@"
}

# Removes the untagged images that carry the Apex label: earlier builds and
# their stages, which no tagged image uses. Never touches a tagged image or
# another project's image. Removing an image can leave its parent untagged
# and unused, so repeat until nothing is left.
apex::prune_untagged() {
  local pass removed
  for ((pass = 0; pass < 10; pass++)); do
    removed="$(podman image prune --force --filter "label=${APEX_LABEL}")"
    [[ -n "${removed}" ]] || break
    echo "Removed $(wc -l <<<"${removed}") untagged Apex image(s)"
  done
}
