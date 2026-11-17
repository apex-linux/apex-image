#!/bin/bash
# Tests the owner's dual-boot install in a virtual machine: a disk laid out
# like the reference machine's (an EFI system partition holding another
# system's loader, a gap, an ext4 partition with known contents) and a UEFI
# boot entry for that system. The installer puts Apex into the gap; the test
# then fails unless the other system's partitions, files and boot entry are
# untouched and an Apex boot entry exists; vm-dualboot-verify.sh then boots
# it, upgrades it once and starts the other system's loader. It uses
# build/vm-disk, replacing any earlier install.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly TOOLS="localhost/apex-iso-tools:45"

vm_dir=""

tools() {
  podman run --rm --volume "${PWD}/image/iso:/tools:ro,z" \
    --volume "${vm_dir}:/out:z" "${TOOLS}" "$@"
}

boot_entries() {
  tools virt-fw-vars --input /out/OVMF_VARS.fd --print 2>/dev/null \
    | grep -E '^Boot([0-9A-F]{4}|Order) +:' | sed 's/^/  /'
}

main() {
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-disk")"
  rm -rf "${vm_dir}"
  mkdir -p "${vm_dir}"

  ssh-keygen -q -t ed25519 -N "" -C apex-vm-test -f "${vm_dir}/id_ed25519"
  "$(dirname "$0")/iso.sh" vm-dualboot "${vm_dir}/id_ed25519.pub"

  tools /tools/dualboot-disk.sh create
  tools /tools/dualboot-disk.sh snapshot before
  cp "$(apex::ovmf OVMF_VARS_4M.fd OVMF_VARS.fd)" "${vm_dir}/OVMF_VARS.fd"
  tools virt-fw-vars --input /out/OVMF_VARS.fd --output /out/OVMF_VARS.fd \
    --append-boot-filepath '\EFI\ubuntu\shimx64.efi' >/dev/null 2>&1
  echo "Boot entries before the install:"
  boot_entries

  # The other system's entry comes first in the boot order, as on a real
  # machine, so the ISO is the boot device of choice, like picking the USB
  # stick in the firmware's boot menu.
  echo "Installing into the gap; the VM powers off when it is done."
  apex::qemu "${vm_dir}" \
    -drive "if=pflash,format=raw,readonly=on,file=$(apex::ovmf \
      OVMF_CODE_4M.fd OVMF_CODE.fd)" \
    -drive "if=pflash,format=raw,file=${vm_dir}/OVMF_VARS.fd" \
    -drive "if=virtio,format=raw,file=${vm_dir}/disk.raw" \
    -drive "if=none,id=cd,media=cdrom,readonly=on,file=${APEX_BUILD_DIR}/iso/apex-installer-vm-dualboot.iso" \
    -device ide-cd,drive=cd,bootindex=0 \
    -nic user,model=virtio-net-pci \
    -no-reboot

  tools /tools/dualboot-disk.sh check
  local entries
  entries="$(boot_entries)"
  echo "Boot entries after the install:"
  echo "${entries}"
  if ! grep -qi 'ubuntu' <<<"${entries}"; then
    apex::err "vm-dualboot: the other system's boot entry is gone"
    exit 1
  fi
  if ! grep -qiE 'apex|fedora' <<<"${entries}"; then
    apex::err "vm-dualboot: the install added no boot entry of its own"
    exit 1
  fi
  echo "Dual-boot install passed; booting it."
  "$(dirname "$0")/vm-dualboot-verify.sh"
  echo "Dual-boot test passed. Boot the result with 'just vm-disk'."
}

main "$@"
