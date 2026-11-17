#!/bin/bash
# Refreshes the system caches that the components' files feed, after they
# are copied into the image. RPMs refresh these in their scriptlets and file
# triggers; a COPY does not, so without this step a component's GSettings
# override or icon theme stays inert. Fails if a cache is older than its
# inputs afterwards.
set -euo pipefail

readonly SCHEMAS=/usr/share/glib-2.0/schemas
readonly ICONS=/usr/share/icons

fail() {
  echo "post-install: $*" >&2
  exit 1
}

main() {
  # A strict dry run rejects an override that names a missing key or a bad
  # value, which the real compile would skip without a word.
  if ! glib-compile-schemas --strict --dry-run "${SCHEMAS}" 2>/tmp/schemas; then
    cat /tmp/schemas >&2
    fail "the GSettings schemas or overrides are invalid"
  fi
  glib-compile-schemas "${SCHEMAS}"

  local index theme
  for index in "${ICONS}"/*/index.theme; do
    theme="${index%/index.theme}"
    gtk-update-icon-cache --force --quiet "${theme}"
  done

  local stale
  stale="$(find "${SCHEMAS}" -name '*.gschema.*' \
    -newer "${SCHEMAS}/gschemas.compiled")"
  [[ -z "${stale}" ]] || fail "gschemas.compiled is older than ${stale}"
  for index in "${ICONS}"/*/index.theme; do
    theme="${index%/index.theme}"
    # A theme that only points elsewhere, such as "default", has no icons
    # and gets no cache.
    if [[ -z "$(find "${theme}" -type f ! -name index.theme -print -quit)" ]]; then
      continue
    fi
    [[ -f "${theme}/icon-theme.cache" ]] || fail "${theme} has no icon cache"
    stale="$(find "${theme}" -newer "${theme}/icon-theme.cache" -print -quit)"
    [[ -z "${stale}" ]] || fail "${theme}/icon-theme.cache is older than ${stale}"
  done
  rm -f /tmp/schemas
  echo "post-install: schemas compiled; icon caches for" \
    "$(find "${ICONS}" -mindepth 2 -maxdepth 2 -name index.theme | wc -l) themes"
}

main "$@"
