#!/bin/bash
# shellcheck disable=SC2016 # The single-quoted script runs in the VM.
# Checks an installed Apex virtual machine after it has booted, over SSH
# (scripts/vm-ssh.sh), and fails with what is wrong: units that failed, a
# hardware clock in local time, the host name, a / line in fstab, the root
# file system's label, and anything under /var with the wrong SELinux label.
set -euo pipefail

main() {
  "$(dirname "$0")/vm-ssh.sh" '
    fail=0
    echo "System state: $(systemctl is-system-running --wait)"
    # mcelog runs only in the VM: on real AMD machines edac_mce_amd skips it,
    # and the virtual CPU offers it nothing to read.
    failed="$(systemctl --failed --no-legend --plain \
      | awk "{ print \$1 }" | grep -vx mcelog.service || true)"
    if [ -n "${failed}" ]; then
      echo "Failed units:"; echo "${failed}"
      fail=1
    else
      echo "Failed units: none"
    fi
    rtc="$(timedatectl show -p LocalRTC --value)"
    echo "Hardware clock in local time: ${rtc} ($(tail -n 1 /etc/adjtime))"
    [ "${rtc}" = no ] || fail=1
    echo "Host name: $(hostname)"
    [ "$(hostname)" = apex ] || fail=1
    if grep -qE "^[^#[:space:]]+[[:space:]]+/[[:space:]]" /etc/fstab; then
      echo "fstab lists /:"; grep -E "[[:space:]]/[[:space:]]" /etc/fstab
      fail=1
    fi
    label="$(btrfs filesystem label /sysroot 2>/dev/null || true)"
    echo "Root file system label: ${label}"
    [ "${label}" = apex ] || fail=1
    wrong="$(restorecon -R -n -v /var 2>&1 | head -n 20)"
    if [ -n "${wrong}" ]; then
      echo "Wrong SELinux labels under /var:"; echo "${wrong}"
      fail=1
    else
      echo "SELinux labels under /var: as the policy says"
    fi
    exit "${fail}"'
}

main "$@"
