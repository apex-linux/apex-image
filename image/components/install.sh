#!/bin/bash
# Runs each component's `just install <destdir>` contract into /out, in the
# order of components.txt. Runs inside the image build, with this directory
# mounted at /run/apex-components and the repositories that
# scripts/components.sh fetched at /run/components.
# Usage: install.sh tools|install
set -euo pipefail

readonly HERE=/run/apex-components
readonly OUT=/out

# Prints a list file without comments and blank lines.
list() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"
}

# Installs what the components' install recipes need, in its own layer.
tools() {
  local -a packages
  mapfile -t packages < <(list "${HERE}/build-tools.txt")
  dnf5 -y install "${packages[@]}"
  dnf5 clean all
}

install() {
  mkdir -p "${OUT}"
  local name dir
  while read -r name; do
    dir="/run/components/${name}"
    if ! just --justfile "${dir}/justfile" --summary 2>/dev/null \
      | tr ' ' '\n' | grep -qx install; then
      echo "Skipping ${name}: it has no 'just install' recipe yet."
      continue
    fi
    echo "Installing ${name}"
    # The repository is mounted read-only; build in a scratch copy.
    cp -a "${dir}" "/var/tmp/${name}"
    just --justfile "/var/tmp/${name}/justfile" \
      --working-directory "/var/tmp/${name}" install "${OUT}"
    rm -rf "/var/tmp/${name}"
  done < <(list "${HERE}/components.txt")

  local stray
  stray="$(find "${OUT}" -mindepth 1 -maxdepth 1 ! -name usr)"
  if [[ -n "${stray}" ]]; then
    echo "A component installed outside <destdir>/usr: ${stray}" >&2
    exit 1
  fi
  find "${OUT}" -type f | sed "s|^${OUT}|  |"
}

main() {
  case "${1:-}" in
    tools) tools ;;
    install) install ;;
    *)
      echo "usage: install.sh tools|install" >&2
      exit 2
      ;;
  esac
}

main "$@"
