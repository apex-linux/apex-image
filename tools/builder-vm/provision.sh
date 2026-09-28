#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest-side provisioning of the Apex builder VM. builder-vm.sh pipes this script into
# `ssh builder@vm bash -s`; it is idempotent and safe to re-run (`builder-vm.sh provision`).
set -euo pipefail

# shellcheck source=/dev/null
. /etc/os-release
if [[ ${ID:-} != fedora || ${VERSION_ID:-} != 45 ]]; then
    echo "provision: expected Fedora 45, found ${PRETTY_NAME:-unknown}" >&2
    exit 1
fi

packages=(
    podman buildah skopeo          # image.sh (rootful)
    jq git-core rsync python3      # helper scripts
    zstd xz tar findutils          # artifacts and layers
    just                           # repository recipes
    qemu-kvm-core edk2-ovmf        # qualify.sh: nested KVM boots with OVMF
    qemu-device-display-virtio-vga # qualify.sh -device virtio-vga (a separate module on Fedora)
    qemu-img                       # desktop-disk.sh: the desktop VM disk, raw to qcow2
    dosfstools btrfs-progs         # qualify.sh: ESP and root of the test disk
    openssh-clients openssl        # qualify.sh: ssh into the guest, key checks
    zram-generator-defaults        # swap on zram for compose peaks
)
sudo dnf5 -y install "${packages[@]}"

# zram swap (zram-generator creates it at boot; start it now on the first run).
if ! swapon --show=NAME --noheadings | grep -q zram; then
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service || true
fi

# Nested KVM for qualification boots; takes effect at the next login.
if [[ -c /dev/kvm ]]; then
    getent group kvm >/dev/null && sudo usermod -aG kvm "$(id -un)"
else
    echo "provision: /dev/kvm is missing in the guest; qualification boots will not work" >&2
fi

echo "provision: done"
printf '  %s\n' "$(podman --version)" "$(skopeo --version)" "$(rpm -q qemu-kvm-core edk2-ovmf | paste -sd ' ')"
printf '  swap: %s\n' "$(swapon --show=NAME,SIZE --noheadings | paste -sd ' ')"
printf '  disk: %s\n' "$(df -h / | awk 'NR == 2 {print $4 " free of " $2}')"
