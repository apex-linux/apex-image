#!/bin/bash
# Boots the disk that `just vm-install` installed, through its bootloader,
# with SSH forwarded to localhost:2222 (see `just vm-ssh`).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

main() {
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"

  local vm_dir
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-disk")"
  # vm-install makes a qcow2 disk, vm-dualboot a raw one.
  local disk format
  for format in qcow2 raw; do
    disk="${vm_dir}/disk.${format}"
    [[ -f "${disk}" ]] && break
  done
  if [[ ! -f "${disk}" ]]; then
    apex::err "vm-disk: no installed disk; run 'just vm-install' first."
    exit 1
  fi

  echo "Booting ${disk}."
  apex::qemu "${vm_dir}" \
    -drive "if=pflash,format=raw,readonly=on,file=$(apex::ovmf \
      OVMF_CODE_4M.fd OVMF_CODE.fd)" \
    -drive "if=pflash,format=raw,file=${vm_dir}/OVMF_VARS.fd" \
    -drive "if=virtio,format=${format},file=${disk}" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22"
}

main "$@"
