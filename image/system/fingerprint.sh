#!/bin/bash
# Turns on fingerprint authentication in PAM, so that the reader can unlock
# the session and authorize administrator actions (the spec's fingerprint
# row: enroll, unlock, authorize). authselect's with-fingerprint feature puts
# pam_fprintd before pam_unix as "sufficient": with no reader, no enrolled
# finger or a failed scan, the password prompt follows as before.
set -euo pipefail

main() {
  authselect enable-feature with-fingerprint
  authselect current
  if ! grep -q pam_fprintd /etc/authselect/system-auth; then
    echo "fingerprint: pam_fprintd is not in system-auth" >&2
    exit 1
  fi
  grep -E 'pam_(fprintd|unix)\.so' /etc/authselect/system-auth
}

main "$@"
