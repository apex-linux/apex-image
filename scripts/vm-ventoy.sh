#!/bin/bash
# Tests the installer on a Ventoy USB stick: lays out a virtual stick with the
# Ventoy files in APEX_VENTOY_DIR (the contents of a real stick's VTOYEFI
# partition) and the test variant of the ISO, boots it through Ventoy's menus
# and fails unless the unattended install onto an empty virtual disk
# completes. Usage: vm-ventoy.sh
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly TOOLS="localhost/apex-iso-tools:45"
readonly VENTOY_DIR="${APEX_VENTOY_DIR:-${APEX_CACHE}/ventoy-1.0.95-vtoyefi}"

# Sends one key to the VM, after a pause for the menu to appear.
key() {
  sleep "$2"
  printf '%s\n' '{"execute":"qmp_capabilities"}' \
    "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"$1\"}]}}" \
    | socat - "UNIX-CONNECT:${vm_dir}/qmp.sock" >/dev/null
}

vm_dir=""

main() {
  if [[ ! -f "${VENTOY_DIR}/ventoy/ventoy.cpio" ]]; then
    apex::err "vm-ventoy: copy a Ventoy stick's VTOYEFI partition to" \
      "${VENTOY_DIR} (or set APEX_VENTOY_DIR) first."
    exit 1
  fi
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-ventoy")"
  rm -rf "${vm_dir}"
  mkdir -p "${vm_dir}"

  ssh-keygen -q -t ed25519 -N "" -C apex-vm-test -f "${vm_dir}/id_ed25519"
  "$(dirname "$0")/iso.sh" vm-test "${vm_dir}/id_ed25519.pub"
  podman run --rm --volume "${PWD}/image/iso:/tools:ro,z" \
    --volume "${VENTOY_DIR}:/ventoy:ro,z" --volume "${vm_dir}:/out:z" \
    --volume "${PWD}/${APEX_BUILD_DIR}/iso/apex-installer-vm-test.iso:/iso.iso:ro,z" \
    "${TOOLS}" /tools/ventoy-disk.sh
  qemu-img create -q -f qcow2 "${vm_dir}/disk.qcow2" 40G
  cp "$(apex::ovmf OVMF_VARS_4M.fd OVMF_VARS.fd)" "${vm_dir}/OVMF_VARS.fd"

  # Ventoy lists the ISO, then offers "Boot in normal mode"; Enter picks
  # both, and the ISO's own menu starts its default entry by itself.
  (key ret 20 && key ret 5) &
  echo "Installing through Ventoy; the VM powers off when it is done."
  apex::qemu "${vm_dir}" \
    -drive "if=pflash,format=raw,readonly=on,file=$(apex::ovmf \
      OVMF_CODE_4M.fd OVMF_CODE.fd)" \
    -drive "if=pflash,format=raw,file=${vm_dir}/OVMF_VARS.fd" \
    -drive "if=none,id=stick,format=raw,file=${vm_dir}/ventoy.raw" \
    -device usb-storage,drive=stick,bootindex=0 \
    -drive "if=virtio,format=qcow2,file=${vm_dir}/disk.qcow2" \
    -nic user,model=virtio-net-pci \
    -no-reboot
  wait

  if ! grep -q 'Deployment complete' "${vm_dir}/serial.log"; then
    apex::err "vm-ventoy: the install through Ventoy did not complete;" \
      "see ${vm_dir}/serial.log"
    exit 1
  fi
  echo "Installed through Ventoy: the installer found its media and its" \
    "kickstart, and the deployment completed."
}

main "$@"
