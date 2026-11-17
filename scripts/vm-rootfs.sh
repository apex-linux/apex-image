#!/bin/bash
# Serves the image's root file system to the virtual machine over virtiofs.
# Runs inside `podman unshare`, the only place where rootless podman can mount
# an image. Usage: vm-rootfs.sh <image> <vm-dir>
set -euo pipefail

# Global, so that the exit trap can see it.
image=""

unmount() {
  podman image unmount "${image}" >/dev/null
}

main() {
  image="$1"
  local vm_dir="$2"

  local root
  root="$(podman image mount "${image}")"
  trap unmount EXIT

  local -a kernels=("${root}"/usr/lib/modules/*/vmlinuz)
  if ((${#kernels[@]} != 1)); then
    echo "vm: expected one kernel in ${image}, found ${#kernels[@]}" >&2
    exit 1
  fi
  # QEMU runs outside this mount namespace, so it gets copies.
  cp "${kernels[0]}" "${vm_dir}/vmlinuz"
  cp "${kernels[0]%/*}/initramfs.img" "${vm_dir}/initramfs.img"

  # The guest keeps its writes in memory, so the image stays read-only.
  /usr/libexec/virtiofsd \
    --socket-path "${vm_dir}/rootfs.sock" \
    --shared-dir "${root}" \
    --sandbox chroot \
    --readonly \
    --cache auto
}

main "$@"
