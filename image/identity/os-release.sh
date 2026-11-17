#!/bin/bash
# Rewrites /usr/lib/os-release so that the image names itself Apex Linux and
# declares Fedora as its parent, as os-release(5) asks of a derivative. Runs
# inside the image build, after the Fedora packages are installed.
set -euo pipefail

readonly OS_RELEASE=/usr/lib/os-release

main() {
  # Fedora's values for the fields that describe the base, not the brand.
  # shellcheck source=/dev/null
  source "${OS_RELEASE}"
  local fedora_version="${VERSION_ID}"
  local fedora_cpe="${CPE_NAME}"
  local fedora_support_end="${SUPPORT_END}"

  # VERSION_ID is the Fedora release the image is built from: Apex has no
  # version scheme of its own yet (OQ-08). CPE_NAME stays Fedora's because
  # vulnerability scanners map the packages through it, and SUPPORT_END is
  # Fedora's because Apex follows Fedora's updates.
  cat >"${OS_RELEASE}" <<EOT
NAME="Apex Linux"
ID=apex
ID_LIKE=fedora
VERSION_ID=${fedora_version}
VERSION="${fedora_version} (Fedora ${fedora_version} base)"
PRETTY_NAME="Apex Linux"
LOGO=fedora-logo-icon
CPE_NAME="${fedora_cpe}"
DEFAULT_HOSTNAME="apex"
HOME_URL="https://github.com/apex-linux"
DOCUMENTATION_URL="https://github.com/apex-linux/apex/tree/main/docs"
BUG_REPORT_URL="https://github.com/apex-linux/apex/issues"
SUPPORT_END=${fedora_support_end}
EOT
  cat "${OS_RELEASE}"
}

main "$@"
