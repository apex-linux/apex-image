#!/bin/bash
# Installs the NVIDIA driver into the nvidia flavor: the module that kmod.sh
# built, mounted at /run/kmod, and negativo17's userspace of the same version.
# Fails unless the module matches the image's kernel and the userspace.
set -euo pipefail

# shellcheck source=../common/dnf.sh
source /run/common/dnf.sh

main() {
  local kver
  kver="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"

  install -m 0644 /run/nvidia/RPM-GPG-KEY-negativo17 /etc/pki/rpm-gpg/
  install -m 0644 /run/nvidia/negativo17.repo /etc/yum.repos.d/
  dnf_install /run/kmod/kmod-nvidia-*.rpm nvidia-driver
  # The image never runs dnf; updates come as a new image.
  rm /etc/yum.repos.d/negativo17.repo

  local vermagic kmod_version driver_version
  vermagic="$(modinfo -F vermagic \
    "/usr/lib/modules/${kver}/extra/nvidia/nvidia.ko.xz")"
  kmod_version="$(rpm -qa 'kmod-nvidia-*' --queryformat '%{VERSION}')"
  driver_version="$(rpm -q nvidia-driver --queryformat '%{VERSION}')"
  echo "Kernel ${kver}; module vermagic ${vermagic}"
  echo "Module ${kmod_version}; userspace ${driver_version}"
  if [[ "${vermagic}" != "${kver} "* ]]; then
    echo "nvidia: the module was built for another kernel" >&2
    exit 1
  fi
  if [[ "${kmod_version}" != "${driver_version}" ]]; then
    echo "nvidia: module and userspace versions differ" >&2
    exit 1
  fi
  depmod -a "${kver}"

  dnf5 clean all
  rm -rf /var/cache/* /var/lib/dnf /var/log/* /var/tmp/*
}

main "$@"
