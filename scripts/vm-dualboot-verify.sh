#!/bin/bash
# shellcheck disable=SC2016 # The single-quoted scripts run in the VM.
# The second half of the dual-boot test (scripts/vm-dualboot.sh): boots the
# installed disk, reports the boot setup, runs one `bootc upgrade` when a
# newer image is published, starts the other system's loader through its
# firmware boot entry with efibootmgr's BootNext, and checks the other
# system's partitions and files once more.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly TOOLS="localhost/apex-iso-tools:45"
readonly MARKER="APEX-TEST-OTHER-LOADER-OK"

vm_dir=""

ssh_vm() {
  "$(dirname "$0")/vm-ssh.sh" "$@"
}

# Waits until SSH in the VM answers (up) or stops answering (down).
wait_ssh() {
  local want="$1" i
  for ((i = 0; i < 100; i++)); do
    if ssh_vm -o ConnectTimeout=3 true 2>/dev/null; then
      [[ "${want}" == up ]] && return 0
    else
      [[ "${want}" == down ]] && return 0
    fi
    sleep 3
  done
  apex::err "vm-dualboot: SSH did not go ${want}"
  exit 1
}

# Prints the digest that ghcr.io serves for the rolling tag.
remote_digest() {
  local token
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:apex-linux/apex:pull" \
    | jq -r .token)"
  curl -fsSI -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    https://ghcr.io/v2/apex-linux/apex/manifests/main \
    | tr -d '\r' | sed -n 's/^docker-content-digest: //Ip'
}

main() {
  apex::lock_heavy
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm-disk")"
  "$(dirname "$0")/vm-disk.sh" >"${vm_dir}/vm-disk.log" 2>&1 &
  local vm_pid=$!
  wait_ssh up

  echo "== First boot"
  "$(dirname "$0")/vm-checks.sh"

  echo "== Installed system"
  ssh_vm 'bootc status --format=humanreadable | head -3
    echo "ostree sysroot.bootloader: $(ostree config get sysroot.bootloader)"
    echo "EFI partition: $(df -B1 --output=avail /boot/efi | tail -1) bytes free"
    efibootmgr | grep -E "^Boot(Order|Current)"
    efibootmgr -v | grep -iE "fedora|ubuntu"
    echo "GRUB entries: $(grep -h ^title /boot/loader/entries/*.conf)"
    grep -qil ubuntu /boot/grub2/grub.cfg /boot/efi/EFI/fedora/grub.cfg \
      && echo "GRUB lists Ubuntu: yes" || echo "GRUB lists Ubuntu: no"'

  echo "== bootc upgrade"
  local before after published
  before="$(ssh_vm bootc status --json | jq -r .status.booted.image.imageDigest)"
  published="$(remote_digest)"
  if [[ -n "${published}" && "${published}" != "${before}" ]]; then
    ssh_vm 'bootc upgrade | tail -2 && systemctl reboot' || true
    wait_ssh down
    wait_ssh up
    after="$(ssh_vm bootc status --json | jq -r .status.booted.image.imageDigest)"
    echo "Booted ${before} before, ${after} after the upgrade"
    if [[ "${after}" == "${before}" ]]; then
      apex::err "vm-dualboot: the upgrade did not change the booted image"
      exit 1
    fi
  else
    echo "UPGRADE NOT EXERCISED: no newer image than ${before} is published"
  fi

  echo "== The other system's loader, through its firmware boot entry"
  ssh_vm 'n="$(efibootmgr -v | grep -i "EFI.ubuntu.shimx64" \
      | sed -n "s/^Boot\([0-9A-F]\{4\}\).*/\1/p" | head -n 1)"
    efibootmgr --bootnext "${n}" | grep BootNext
    systemctl reboot' || true
  local i
  for ((i = 0; i < 60; i++)); do
    kill -0 "${vm_pid}" 2>/dev/null || break
    sleep 3
  done
  if ! grep -q "${MARKER}" "${vm_dir}/serial.log"; then
    kill "${vm_pid}" 2>/dev/null || true
    apex::err "vm-dualboot: the other system's loader did not start"
    exit 1
  fi
  echo "The other system's loader started and printed ${MARKER}"
  wait "${vm_pid}" || true

  echo "== The other system's partitions and files, after all of the above"
  podman run --rm --volume "${PWD}/image/iso:/tools:ro,z" \
    --volume "${vm_dir}:/out:z" "${TOOLS}" /tools/dualboot-disk.sh check
}

main "$@"
