#!/bin/bash
# Shared settings for the recipes in the justfile. Sourced, not run.
# shellcheck disable=SC2034 # The scripts that source this file use these.

readonly APEX_CACHE="${HOME}/.cache/apex"
readonly APEX_BUILD_DIR="build"
readonly APEX_IMAGE="${APEX_IMAGE:-localhost/apex:main}"
# Every image this repository builds carries this label, intermediate layers
# included, so `just clean` can find them without touching other projects.
readonly APEX_LABEL="org.opencontainers.image.source=https://github.com/apex-linux/apex-image"

apex::err() {
  echo "$*" >&2
}

# Takes the machine-wide lock for heavy work, so that two sessions never
# build or boot at the same time. The lock is released when the shell exits.
apex::lock_heavy() {
  mkdir -p "${APEX_CACHE}"
  exec 9>"${APEX_CACHE}/heavy.lock"
  if ! flock --nonblock 9; then
    apex::err "Another heavy Apex job holds ${APEX_CACHE}/heavy.lock; try later."
    exit 1
  fi
}
