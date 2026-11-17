#!/bin/bash
# Installs the Fedora GNOME desktop into the image. Runs inside the image
# build, with this directory mounted at /run/desktop.
set -euo pipefail

readonly PACKAGES=/run/desktop/packages

# Prints a package list without comments and blank lines.
list() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"
}

# Mirrors sometimes serve metadata in the middle of a sync, which fails its
# checksum. Retry with fresh metadata before giving up.
dnf_install() {
  local attempt
  for attempt in 1 2 3; do
    if dnf5 -y install "$@"; then
      return 0
    fi
    echo "dnf5 install failed (attempt ${attempt} of 3)" >&2
    dnf5 clean metadata
  done
  return 1
}

main() {
  local -a args
  mapfile -t args < <(list "${PACKAGES}/groups.txt" | sed 's/^/@/')
  local exclude
  exclude="$(list "${PACKAGES}/exclude.txt" | paste -sd , -)"
  if [[ -n "${exclude}" ]]; then
    args+=("--exclude=${exclude}")
  fi
  dnf_install "${args[@]}"

  systemctl enable gdm.service
  systemctl set-default graphical.target

  # /var belongs to the installed system; the image must leave it empty.
  dnf5 clean all
  rm -rf /var/cache/* /var/lib/dnf /var/log/* /var/tmp/* /tmp/*
}

main "$@"
