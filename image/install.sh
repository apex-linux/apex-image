#!/bin/bash
# Installs the Fedora GNOME desktop into the image. Runs inside the image
# build, with this directory mounted at /run/image.
set -euo pipefail

readonly PACKAGES=/run/image/packages

# Prints a package list without comments and blank lines.
list() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"
}

main() {
  local -a args
  mapfile -t args < <(list "${PACKAGES}/groups.txt" | sed 's/^/@/')
  local exclude
  exclude="$(list "${PACKAGES}/exclude.txt" | paste -sd , -)"
  if [[ -n "${exclude}" ]]; then
    args+=("--exclude=${exclude}")
  fi
  dnf5 -y install "${args[@]}"

  systemctl enable gdm.service
  systemctl set-default graphical.target

  # /var belongs to the installed system; the image must leave it empty.
  dnf5 clean all
  rm -rf /var/cache/* /var/lib/dnf /var/log/* /var/tmp/* /tmp/*
}

main "$@"
