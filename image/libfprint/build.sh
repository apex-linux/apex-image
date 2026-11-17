#!/bin/bash
# Rebuilds Fedora's libfprint with the patch series that apex-hardware
# carries (docs/adr/0002-elan-fingerprint-patches.md there), into /rpms. If a
# patch no longer applies, it builds nothing, and the image keeps Fedora's
# package. Runs in a builder stage, with the fetched component repositories
# mounted at /run/components and image/common at /run/common.
set -euo pipefail

# shellcheck source=../common/dnf.sh
source /run/common/dnf.sh

readonly PATCHES=/run/components/apex-hardware/patches/libfprint
readonly TOP=/var/tmp/libfprint
readonly OUT=/rpms

skip() {
  echo "libfprint: $*; the image ships Fedora's libfprint unchanged." \
    | tee "${OUT}/STATUS"
  exit 0
}

main() {
  mkdir -p "${OUT}" "${TOP}"
  if [[ ! -f "${PATCHES}/series" ]]; then
    skip "apex-hardware carries no patch series"
  fi

  local -a patches
  mapfile -t patches < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' \
    "${PATCHES}/series")

  dnf_install rpm-build dnf5-plugins
  cd "${TOP}"
  dnf5 download --source libfprint
  rpm -i --define "_topdir ${TOP}" libfprint-*.src.rpm

  # Fedora's spec applies its patches with %autosetup -S git, so numbered
  # Patch lines after Source0 are enough.
  local spec="${TOP}/SPECS/libfprint.spec" lines="" patch n=9001
  for patch in "${patches[@]}"; do
    cp "${PATCHES}/${patch}" "${TOP}/SOURCES/"
    lines+="Patch${n}: ${patch}\n"
    n=$((n + 1))
  done
  sed -i "/^Source0:/a ${lines%\\n}" "${spec}"

  local -a define=(--define "_topdir ${TOP}"
    --define "dist $(rpm -E '%dist').apex")
  dnf5 -y builddep "${spec}"
  if ! rpmbuild -bp "${define[@]}" "${spec}"; then
    skip "a patch in apex-hardware's series no longer applies"
  fi
  rpmbuild -bb "${define[@]}" "${spec}"
  cp "${TOP}"/RPMS/*/libfprint-[0-9]*.rpm "${OUT}/"
  echo "libfprint: rebuilt with ${patches[*]}" | tee "${OUT}/STATUS"
}

main "$@"
