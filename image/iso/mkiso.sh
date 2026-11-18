#!/bin/bash
# Embeds a kickstart in Fedora's netinst ISO without loop devices, so that it
# runs in rootless Podman. Runs inside the tools image (image/iso).
# Usage: mkiso.sh <input-iso> <output-iso> [mkksiso options...]
set -euo pipefail

# Global, so that the exit trap can see it.
work=""

cleanup() {
  rm -rf "${work}"
}

main() {
  local input="$1" output="$2"
  shift 2
  work="$(mktemp -d /out/work.XXXXXX)"
  trap cleanup EXIT

  # Ventoy before 1.1.18 installs its initramfs hooks into
  # /lib/dracut/hooks, but Fedora 45's dracut (dracut-ng) runs them from
  # /var/lib/dracut/hooks, so Ventoy's hook never maps the ISO and the
  # installer waits for its media forever. A second initrd holds the old
  # path, as a link to the new one, which lets those Ventoy versions work;
  # dracut itself does not use the old path. It also carries the hooks in
  # /tools/initrd that explain in plain words when the installer cannot
  # find its media, instead of leaving a looping prompt.
  mkdir -p "${work}/compat/usr/lib/dracut"
  cp -a /tools/initrd/. "${work}/compat/"
  ln -s /var/lib/dracut/hooks "${work}/compat/usr/lib/dracut/hooks"
  (cd "${work}/compat" && find usr var | cpio --quiet -o -H newc -R 0:0) \
    >"${work}/apex-compat.img"

  # mkksiso edits the boot menus on the ISO file system. Its mkefiboot step,
  # which rebuilds the EFI partition, needs a loop device, so skip it and
  # patch the menu in that partition below instead.
  mkksiso --skip-mkefiboot --tmp "${work}" "$@" \
    --add "${work}/apex-compat.img" \
    --replace "/images/pxeboot/initrd.img" \
    "/images/pxeboot/initrd.img /apex-compat.img" \
    "${input}" "${output}"

  # The EFI system partition is appended to the ISO: find it, copy it out,
  # replace its grub.cfg with the edited one and write it back in place.
  local start size
  read -r start size < <(xorriso -indev "${output}" \
    -report_el_torito as_mkisofs 2>/dev/null \
    | sed -n 's/.*appended_partition_2_start_\([0-9]*\)s_size_\([0-9]*\)d.*/\1 \2/p')
  if [[ -z "${start}" ]]; then
    echo "mkiso: no appended EFI partition in ${output}" >&2
    exit 1
  fi
  # The report counts the start in 2048-byte sectors and the size in
  # 512-byte blocks.
  local offset=$((start * 2048))
  dd if="${output}" of="${work}/esp.img" bs=512 skip=$((offset / 512)) \
    count="${size}" status=none
  xorriso -osirrox on -indev "${output}" \
    -extract /EFI/BOOT/grub.cfg "${work}/grub.cfg" 2>/dev/null
  mcopy -o -i "${work}/esp.img" "${work}/grub.cfg" ::/EFI/BOOT/grub.cfg
  mcopy -o -i "${work}/esp.img" "${work}/grub.cfg" ::/EFI/BOOT/BOOT.conf
  dd if="${work}/esp.img" of="${output}" bs=512 seek=$((offset / 512)) \
    conv=notrunc status=none
  # The media check covers the EFI partition too: implant the new checksum.
  implantisomd5 --force "${output}" >/dev/null
  checkisomd5 "${output}" >/dev/null
  echo "EFI boot menu:"
  mtype -i "${work}/esp.img" ::/EFI/BOOT/grub.cfg | grep -E '^\s*linux'
}

main "$@"
