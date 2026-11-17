#!/bin/bash
# Builds and checks a virtual disk laid out like the reference machine's,
# for the dual-boot test (scripts/vm-dualboot.sh). Runs inside the tools image
# with the test directory at /out; needs no loop device.
#   create:   GPT; p1 a 700 MiB EFI system partition named as on the real
#             disk, holding a 196 MiB vfat file system with another
#             system's loader under EFI/ubuntu;
#             a 30 GiB gap; p4 a 2 GiB ext4 partition with known files.
#   snapshot: records what must not change into /out/<name>.txt.
#   check:    compares the disk with snapshot "before".
# Usage: dualboot-disk.sh create|snapshot <name>|check
set -euo pipefail

readonly DISK=/out/disk.raw
readonly ESP_START=2048 ESP_SIZE=1433600 # sectors, as on the real disk
readonly ROOT_SIZE=4194304               # 2 GiB in sectors
readonly GAP=62914560                    # 30 GiB in sectors
# The real p1's GPT name (PARTNAME in sysfs); p4 has none.
readonly ESP_NAME="EFI System Partition"

esp() { echo "${DISK}@@$((ESP_START * 512))"; }

create() {
  local root_start=$((ESP_START + ESP_SIZE + GAP))
  rm -f "${DISK}"
  truncate -s $(((root_start + ROOT_SIZE + 2048) * 512)) "${DISK}"
  sfdisk --quiet "${DISK}" <<EOF
label: gpt
${DISK}1 : start=${ESP_START}, size=${ESP_SIZE}, type=U, name="${ESP_NAME}"
${DISK}4 : start=${root_start}, size=${ROOT_SIZE}, type=L
EOF
  # The real ESP's file system is smaller than its partition.
  mkfs.vfat -C -n ESP /tmp/esp.img $((196 * 1024)) >/dev/null
  dd if=/tmp/esp.img of="${DISK}" bs=512 seek="${ESP_START}" conv=notrunc \
    status=none
  mmd -i "$(esp)" ::/EFI ::/EFI/ubuntu ::/EFI/Boot
  local f
  for f in ubuntu/shimx64.efi ubuntu/grubx64.efi ubuntu/mmx64.efi \
    ubuntu/BOOTX64.CSV ubuntu/grub.cfg Boot/bootx64.efi Boot/fbx64.efi; do
    head -c 1048576 /dev/urandom >/tmp/file
    mcopy -i "$(esp)" /tmp/file "::/EFI/${f}"
  done
  mkdir -p /tmp/root/home/owner
  head -c 8388608 /dev/urandom >/tmp/root/home/owner/data.bin
  echo "Ubuntu stays." >/tmp/root/etc-hostname
  mkfs.ext4 -q -L ubuntu -d /tmp/root /tmp/root.img 2G
  dd if=/tmp/root.img of="${DISK}" bs=512 seek="${root_start}" conv=notrunc \
    status=none
  rm -rf /tmp/esp.img /tmp/file /tmp/root /tmp/root.img
}

# Prints the facts that must survive the install, one per line.
facts() {
  sfdisk --dump "${DISK}" | grep -E "^${DISK}[14] "
  local start size
  read -r start size < <(sfdisk --dump "${DISK}" \
    | sed -n "s|^${DISK}4 : start= *\([0-9]*\), size= *\([0-9]*\).*|\1 \2|p")
  echo "p4 sha256 $(dd if="${DISK}" bs=512 skip="${start}" count="${size}" \
    status=none | sha256sum | cut -d ' ' -f 1)"
  echo "p1 $(minfo -i "$(esp)" :: | grep -E 'serial number|volume label')"
  esp_sums ubuntu
}

# Prints the checksums of the files in one directory under EFI on p1.
esp_sums() {
  rm -rf /tmp/sums
  mcopy -s -n -i "$(esp)" "::/EFI/$1" /tmp/sums
  (cd /tmp/sums && find . -type f -exec sha256sum {} + | sort -k 2)
  rm -rf /tmp/sums
}

check() {
  facts >/out/after.txt
  echo "Partitions after the install:"
  sfdisk --list --output Device,Start,End,Size,Type "${DISK}" | tail -n +8
  echo "Files on p1 after the install:"
  mdir -/ -b -i "$(esp)" ::/EFI | sed 's/^/  /'
  if ! diff -u /out/before.txt /out/after.txt; then
    echo "dualboot: the other system's partitions or files changed" >&2
    exit 1
  fi
  echo "dualboot: p1 and p4 table entries, p4 contents, p1's file system and" \
    "EFI/ubuntu are unchanged"
  # The firmware's fallback loader is shared; the installer may replace it.
  if esp_sums Boot | cmp -s - /out/before-fallback.txt; then
    echo "dualboot: EFI/Boot (the firmware fallback) is unchanged"
  else
    echo "dualboot: EFI/Boot (the firmware fallback) was replaced"
  fi
}

main() {
  case "${1:-}" in
    create) create ;;
    snapshot)
      facts >"/out/$2.txt"
      esp_sums Boot >"/out/$2-fallback.txt"
      ;;
    check) check ;;
    *)
      echo "usage: dualboot-disk.sh create|snapshot <name>|check" >&2
      exit 2
      ;;
  esac
}

main "$@"
