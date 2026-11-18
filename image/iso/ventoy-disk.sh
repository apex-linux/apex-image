#!/bin/bash
# Lays out a virtual USB stick the way Ventoy installs itself, for
# scripts/vm-ventoy.sh, without root or loop devices: an MBR with Ventoy's
# boot code signature, partition 1 holding the ISO and partition 2, VTOYEFI,
# holding Ventoy's boot files. Runs inside the tools image with the Ventoy
# files at /ventoy, the ISO at /iso.iso and the output directory at /out.
# Partition 1 is FAT32 here; Ventoy maps the ISO by its sectors, whatever
# the file system, and the exFAT case was checked by hand.
set -euo pipefail

readonly DISK=/out/ventoy.raw
# The sizes of the owner's 64 GB stick, in sectors.
readonly DISK_SECTORS=120176640 DATA_START=2048 DATA_SECTORS=120109056
readonly EFI_START=120111104 EFI_SECTORS=65536

main() {
  rm -f "${DISK}"
  truncate -s $((DISK_SECTORS * 512)) "${DISK}"
  sfdisk --quiet "${DISK}" <<EOT
label: dos
${DISK}1 : start=${DATA_START}, size=${DATA_SECTORS}, type=7, bootable
${DISK}2 : start=${EFI_START}, size=${EFI_SECTORS}, type=ef
EOT
  mkfs.fat -F 32 -n IMAGES --offset "${DATA_START}" "${DISK}" \
    $((DATA_SECTORS / 2)) >/dev/null 2>&1
  mkfs.fat -F 16 -n VTOYEFI --offset "${EFI_START}" "${DISK}" \
    $((EFI_SECTORS / 2)) >/dev/null
  mcopy -i "${DISK}@@$((DATA_START * 512))" /iso.iso ::/apex-installer.iso
  mcopy -s -i "${DISK}@@$((EFI_START * 512))" /ventoy/EFI /ventoy/grub \
    /ventoy/ventoy /ventoy/tool ::/

  # Ventoy's GRUB refuses a disk whose MBR lacks its boot code's first
  # bytes and its signature at 0x190 (ventoy_cmd.c, g_check_mbr_data); the
  # disk's ID sits at 0x180.
  python3 -I - "${DISK}" <<'PY'
import os
import sys

with open(sys.argv[1], "r+b") as disk:
    disk.seek(0)
    disk.write(bytes([0xEB, 0x63, 0x90]) + bytes(0x2D))
    disk.seek(0x180)
    disk.write(os.urandom(16))
    disk.seek(0x190)
    disk.write(bytes.fromhex("5654004765004844005264002045720d"))
PY
}

main "$@"
