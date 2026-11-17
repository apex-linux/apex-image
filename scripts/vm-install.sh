#!/bin/bash
# Installs Apex Linux from the installer ISO onto an empty virtual disk, the
# way the USB stick installs it, but unattended: a test variant of the ISO
# picks the virtual disk and adds an SSH key for root. The installer pulls
# ghcr.io/apex-linux/apex:main, so this tests the published image.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly DISK_SIZE="40G"

main() {
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"

  local vm_dir
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-disk")"
  rm -rf "${vm_dir}"
  mkdir -p "${vm_dir}"

  ssh-keygen -q -t ed25519 -N "" -C apex-vm-test -f "${vm_dir}/id_ed25519"
  "$(dirname "$0")/iso.sh" vm-test "${vm_dir}/id_ed25519.pub"

  qemu-img create -q -f qcow2 "${vm_dir}/disk.qcow2" "${DISK_SIZE}"
  cp "$(apex::ovmf OVMF_VARS_4M.fd OVMF_VARS.fd)" "${vm_dir}/OVMF_VARS.fd"

  echo "Installing from the ISO; the VM powers off when it is done."
  apex::qemu "${vm_dir}" \
    -drive "if=pflash,format=raw,readonly=on,file=$(apex::ovmf \
      OVMF_CODE_4M.fd OVMF_CODE.fd)" \
    -drive "if=pflash,format=raw,file=${vm_dir}/OVMF_VARS.fd" \
    -drive "if=virtio,format=qcow2,file=${vm_dir}/disk.qcow2" \
    -drive "media=cdrom,readonly=on,file=${APEX_BUILD_DIR}/iso/apex-installer-vm-test.iso" \
    -nic user,model=virtio-net-pci \
    -no-reboot
  echo "Installed. Boot it with 'just vm-disk'."
}

main "$@"
