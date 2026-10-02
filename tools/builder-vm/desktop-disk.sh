#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: desktop-disk.sh IMAGE AUTHORIZED_KEY

Guest-side disk build for `desktop-vm.sh install`, run in ~/apex-fedora inside the
builder VM. It installs a local image with the qualification's install_disk onto a
disk laid out like the laptop minus LUKS (ESP + ext4 /boot + btrfs root), then
converts the disk to qcow2 for the host.

IMAGE is an image in local container storage, e.g. localhost/apex:build from
`builder-vm.sh image`. AUTHORIZED_KEY is the desktop VM's SSH public key (one
ssh-ed25519 line). It becomes root's only key, and a kernel argument starts sshd,
which the image ships disabled; the host forwards it on 127.0.0.1 only. Unlike the
qualification, the Flatpak units are not masked and there is no serial console: the
first boot runs the Flatpak preinstall as on the laptop.

Output in _build/desktop/DESKTOP_OUT: desktop.qcow2, desktop.json (image, digest,
version, disk_gb) and authorized_keys.
Environment: DESKTOP_DISK_GB (default 64), the virtual size; the qcow2 grows on
demand. DESKTOP_OUT (default: default), the output directory's name, [0-9a-z-]; each
desktop VM has its own, so that two installs never share a disk or a key.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
if (($# != 2)); then
    usage >&2
    exit 2
fi
image=$1
key=$2

readonly DESKTOP_OUT=${DESKTOP_OUT:-default}
export QUALIFY_OUT="$HOME/apex-fedora/_build/desktop/$DESKTOP_OUT"
export QUALIFY_LAYOUT=separate-boot
export QUALIFY_DISK_GB=${DESKTOP_DISK_GB:-64}
# qualify.sh only runs its main when executed; sourced, it provides install_disk.
# shellcheck source=SCRIPTDIR/../../.github/scripts/qualify.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../../.github/scripts/qualify.sh"

# The qualification's serial console would take /dev/console from the boot splash, and
# its Flatpak masks are for unattended test boots.
install_kargs() { printf '%s\n' --karg systemd.wants=sshd.service; }

[[ $image =~ ^localhost/[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] ||
    die "expected a local image reference localhost/NAME[:TAG], got '$image'"
[[ $key =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}(\ [[:print:]]*)?$ ]] ||
    die "AUTHORIZED_KEY must be a single ssh-ed25519 public key line"
[[ $DESKTOP_OUT =~ ^[0-9a-z-]+$ ]] || die "DESKTOP_OUT must be a directory name of [0-9a-z-], got '$DESKTOP_OUT'"
if [[ ! $QUALIFY_DISK_GB =~ ^[1-9][0-9]*$ ]] || ((QUALIFY_DISK_GB < 20)); then
    die "DESKTOP_DISK_GB must be a whole number of GiB, at least 20 (got '$QUALIFY_DISK_GB')"
fi
require podman jq qemu-img truncate sfdisk losetup partx mkfs.vfat mkfs.ext4 mkfs.btrfs

digest=$(as_root podman image inspect --format '{{.Digest}}' "$image") ||
    die "$image is not in local container storage (build it with: builder-vm.sh image)"
# CI sets the version label when it publishes; a local build has none.
version=$(as_root podman image inspect \
    --format '{{index .Labels "org.opencontainers.image.version"}}' "$image")
version=${version:-unversioned}

disk=$QUALIFY_OUT/desktop.raw
out=$QUALIFY_OUT/desktop.qcow2

cleanup_desktop() {
    local rc=$? l
    unmount_all
    for l in "${LOOPS[@]}"; do as_root losetup --detach "$l" 2>/dev/null || true; done
    rm -f -- "$disk" "$out.part"
    exit "$rc"
}
trap cleanup_desktop EXIT

mkdir -p "$QUALIFY_OUT"
rm -f -- "$out" "$QUALIFY_OUT/desktop.json"
printf '%s\n' "$key" >"$QUALIFY_OUT/authorized_keys"

install_disk desktop "$image" "$APEX_REPO_TESTING:$APEX_FEDORA"

group "Convert $disk to qcow2"
qemu-img convert -O qcow2 "$disk" "$out.part"
mv -f -- "$out.part" "$out"
rm -f -- "$disk"
endgroup

jq -n --arg image "$image" --arg digest "$digest" --arg version "$version" \
    --argjson disk_gb "$QUALIFY_DISK_GB" \
    '{image: $image, digest: $digest, version: $version, disk_gb: $disk_gb}' \
    >"$QUALIFY_OUT/desktop.json"
log "desktop disk: $out ($(du -h "$out" | cut -f1) used), $image $version $digest"
