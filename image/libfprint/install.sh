#!/bin/bash
# Replaces Fedora's libfprint with the patched build from the libfprint
# stage, mounted at /run/libfprint-rpms, when there is one.
set -euo pipefail

main() {
  cat /run/libfprint-rpms/STATUS
  local -a rpms=(/run/libfprint-rpms/*.rpm)
  if [[ -f "${rpms[0]}" ]]; then
    # Same dependencies as Fedora's build, so rpm needs no repositories. The
    # package was built moments ago in this build, from Fedora's signed
    # source package, and Apex has no package signing key (M3).
    rpm -Uvh --nosignature "${rpms[@]}"
  fi
  rpm -q libfprint
}

main "$@"
