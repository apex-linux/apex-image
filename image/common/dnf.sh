#!/bin/bash
# Shared by the scripts that run inside the image build. Sourced, not run.

# Installs packages with dnf5. Mirrors sometimes serve metadata in the middle
# of a sync, which fails its checksum, so retry with fresh metadata before
# giving up.
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
