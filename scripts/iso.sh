#!/bin/bash
# Builds the Apex Linux installer: Fedora's netinst ISO with the Apex
# kickstart embedded. The installer pulls the image from the registry, so the
# ISO stays the size of Fedora's netinst.
# Usage: iso.sh [vm-test|vm-dualboot <ssh-public-key>]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

readonly FEDORA_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Everything/x86_64/iso"
readonly FEDORA_ISO="Fedora-Everything-netinst-x86_64-45-1.4.iso"
readonly FEDORA_CHECKSUM="Fedora-Everything-45-1.4-x86_64-CHECKSUM"
readonly FEDORA_KEY="/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-45-primary"
readonly TOOLS="localhost/apex-iso-tools:45"
readonly CACHE="${APEX_CACHE}/iso"

tools() {
  podman run --rm --volume "${CACHE}:/iso:ro,z" \
    --volume "${PWD}/image/iso:/tools:ro,z" \
    --volume "${PWD}/${APEX_BUILD_DIR}/iso:/out:z" "${TOOLS}" "$@"
}

fetch() {
  local file="$1"
  if [[ ! -f "${CACHE}/${file}" ]]; then
    echo "Downloading ${FEDORA_URL}/${file}"
    curl --fail --location --silent --show-error \
      --output "${CACHE}/${file}.part" "${FEDORA_URL}/${file}"
    mv "${CACHE}/${file}.part" "${CACHE}/${file}"
  fi
}

main() {
  local variant="${1:-}" key="${2:-}"
  apex::lock_heavy
  "$(dirname "$0")/doctor.sh"
  mkdir -p "${CACHE}" "${APEX_BUILD_DIR}/iso"
  podman build --quiet --tag "${TOOLS}" image/iso >/dev/null

  fetch "${FEDORA_CHECKSUM}"
  fetch "${FEDORA_ISO}"
  # The checksum file is signed with the Fedora 45 key in the tools image.
  tools bash -c "gpg --dearmor <${FEDORA_KEY} >/tmp/fedora.gpg \
    && gpgv --keyring /tmp/fedora.gpg /iso/${FEDORA_CHECKSUM} \
    && cd /iso && sha256sum --ignore-missing --check ${FEDORA_CHECKSUM}"

  local ks="${APEX_BUILD_DIR}/iso/apex.ks" out="apex-installer.iso"
  # Name Apex in the boot menu entries, which end in "Fedora 45'".
  local -a args=(--replace "Fedora 45'" "Apex Linux'")
  cp image/iso/apex.ks "${ks}"
  if [[ "${variant}" == vm-test || "${variant}" == vm-dualboot ]]; then
    cat "image/iso/${variant}.ks" >>"${ks}"
    echo "sshkey --username=root \"$(cat "${key}")\"" >>"${ks}"
    out="apex-installer-${variant}.iso"
    # Skip the media check and log to the serial console of the test VM.
    args+=(--rm-args "rd.live.check quiet" --cmdline "inst.text console=ttyS0")
  elif [[ -n "${variant}" ]]; then
    apex::err "usage: iso.sh [vm-test|vm-dualboot <ssh-public-key>]"
    exit 2
  fi

  rm -f "${APEX_BUILD_DIR}/iso/${out}"
  tools /tools/mkiso.sh "/iso/${FEDORA_ISO}" "/out/${out}" \
    "${args[@]}" --ks /out/apex.ks
  ls -l "${APEX_BUILD_DIR}/iso/${out}"
}

main "$@"
