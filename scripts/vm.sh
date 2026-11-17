#!/bin/bash
# Boots the built image in a QEMU virtual machine, without root. The guest
# boots the image's own kernel and reads its root file system from container
# storage over virtiofs; its writes go to memory and vanish on power-off.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly MEMORY="4G"
readonly CPUS="$(($(nproc) / 2))"
# gtk opens a window; none runs headless (take screenshots over QMP).
readonly VM_DISPLAY="${APEX_VM_DISPLAY:-gtk}"
# The volatile root starts with no users, so skip GNOME Initial Setup and go
# straight to the greeter. SELinux is off because virtiofs from rootless
# container storage carries no SELinux labels.
readonly KARGS="root=rootfs rootfstype=virtiofs ro systemd.volatile=overlay
selinux=0 gnome.initial-setup=0 console=ttyS0 console=tty0"

wait_for() {
  local path="$1" pid="$2" i
  for ((i = 0; i < 120; i++)); do
    [[ -S "${path}" ]] && return 0
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  apex::err "vm: ${path} did not appear; see the messages above."
  exit 1
}

# Global, so that the exit trap can see it.
rootfs_pid=""

# virtiofsd exits when QEMU disconnects and then unmounts the image. Kill it
# only if QEMU never connected.
stop_rootfs() {
  local i
  for ((i = 0; i < 20; i++)); do
    kill -0 "${rootfs_pid}" 2>/dev/null || break
    sleep 0.5
  done
  kill "${rootfs_pid}" 2>/dev/null || true
  wait "${rootfs_pid}" 2>/dev/null || true
}

main() {
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"
  if ! podman image exists "${APEX_IMAGE}"; then
    apex::err "vm: ${APEX_IMAGE} does not exist; run 'just build' first."
    exit 1
  fi

  local vm_dir
  vm_dir="$(realpath -m "${APEX_BUILD_DIR}/vm")"
  rm -rf "${vm_dir}"
  mkdir -p "${vm_dir}"

  podman unshare "$(dirname "$0")/vm-rootfs.sh" "${APEX_IMAGE}" "${vm_dir}" &
  rootfs_pid=$!
  trap stop_rootfs EXIT
  wait_for "${vm_dir}/rootfs.sock" "${rootfs_pid}"

  echo "Booting ${APEX_IMAGE}: ${MEMORY} memory, ${CPUS} CPUs."
  echo "Serial console: ${vm_dir}/serial.log. QMP: ${vm_dir}/qmp.sock."
  qemu-system-x86_64 \
    -name apex \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "${CPUS}" \
    -m "${MEMORY}" \
    -object "memory-backend-memfd,id=mem,size=${MEMORY},share=on" \
    -numa node,memdev=mem \
    -chardev "socket,id=rootfs,path=${vm_dir}/rootfs.sock" \
    -device vhost-user-fs-pci,chardev=rootfs,tag=rootfs \
    -kernel "${vm_dir}/vmlinuz" \
    -initrd "${vm_dir}/initramfs.img" \
    -append "${KARGS//$'\n'/ }" \
    -device virtio-vga \
    -device qemu-xhci \
    -device usb-tablet \
    -nic user,model=virtio-net-pci \
    -display "${VM_DISPLAY}" \
    -serial "file:${vm_dir}/serial.log" \
    -qmp "unix:${vm_dir}/qmp.sock,server=on,wait=off"
}

main "$@"
