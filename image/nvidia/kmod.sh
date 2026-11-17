#!/bin/bash
# Builds the NVIDIA open kernel module for the image's kernel from
# negativo17's akmod-nvidia, into /rpms, as apex-hardware's ADR 0001 decides.
# The module is not signed: Secure Boot stays off until M3. Runs in a builder
# stage with this directory at /run/nvidia and image/common at /run/common.
set -euo pipefail

# shellcheck source=../common/dnf.sh
source /run/common/dnf.sh

readonly OUT=/rpms

main() {
  local kver
  kver="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
  echo "Building the NVIDIA module for kernel ${kver}"

  install -m 0644 /run/nvidia/RPM-GPG-KEY-negativo17 /etc/pki/rpm-gpg/
  install -m 0644 /run/nvidia/negativo17.repo /etc/yum.repos.d/
  dnf_install akmod-nvidia "kernel-devel-${kver}"

  akmods --force --kernels "${kver}" --kmod nvidia
  local module="/usr/lib/modules/${kver}/extra/nvidia/nvidia.ko.xz"
  if [[ ! -f "${module}" ]]; then
    cat /var/cache/akmods/nvidia/*.failed.log >&2 || true
    echo "nvidia: akmods built no module for ${kver}" >&2
    exit 1
  fi
  modinfo -F vermagic "${module}"
  mkdir -p "${OUT}"
  cp /var/cache/akmods/nvidia/kmod-nvidia-*.rpm "${OUT}/"
  ls "${OUT}"
}

main "$@"
