#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# builder-vm.sh pipes this into `ssh builder@vm bash -s`; it must stay safe to re-run.
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
    rpm-sign gnupg2                # the Apex RPM key: rpmsign in apex-lane and build-image.sh
    zstd xz tar findutils          # artifacts and layers
    just                           # repository recipes
    qemu-kvm-core edk2-ovmf        # qualify.sh: nested KVM boots with OVMF
    qemu-device-display-virtio-vga # qualify.sh -device virtio-vga (a separate module on Fedora)
    qemu-img                       # desktop-disk.sh: the desktop VM disk, raw to qcow2
    dosfstools btrfs-progs         # qualify.sh: ESP and root of the test disk
    openssh-clients openssl        # qualify.sh: ssh into the guest, key checks
    cryptsetup                     # qualify.sh QUALIFY_LAYOUT=luks (just vm-qualify-luks)
    curl                           # install-cosign.sh: Fedora packages no cosign
    zram-generator-defaults        # swap on zram for compose peaks
)
sudo dnf5 -y install "${packages[@]}"

# zram-generator makes the swap unit at boot; daemon-reload runs it now.
if ! swapon --show=NAME --noheadings | grep -q zram; then
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service || true
fi

if [[ -c /dev/kvm ]]; then
    getent group kvm >/dev/null && sudo usermod -aG kvm "$(id -un)"
else
    echo "provision: /dev/kvm is missing in the guest; qualification boots will not work" >&2
fi

echo "provision: done"
printf '  %s\n' "$(podman --version)" "$(skopeo --version)" "$(rpm -q qemu-kvm-core edk2-ovmf | paste -sd ' ')"
printf '  swap: %s\n' "$(swapon --show=NAME,SIZE --noheadings | paste -sd ' ')"
printf '  disk: %s\n' "$(df -h / | awk 'NR == 2 {print $4 " free of " $2}')"
