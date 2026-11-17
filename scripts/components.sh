#!/bin/bash
# Fetches each component repository at the commit the build uses: the tip of
# main, or the pin in a release sync file. Prints one component=commit line
# per component. Usage: components.sh <dest-dir> [sync-file]
set -euo pipefail

readonly ORG_URL="https://github.com/apex-linux"
readonly LIST="image/components/components.txt"

# Prints the commit pinned for a component in a sync file.
pinned() {
  local name="$1" sync="$2" commit
  commit="$(sed -n "s/^${name}=\([0-9a-f]\{40\}\)$/\1/p" "${sync}")"
  if [[ -z "${commit}" ]]; then
    echo "components: ${sync} has no ${name}=<commit> line" >&2
    exit 1
  fi
  echo "${commit}"
}

main() {
  local dest="$1" sync="${2:-}"
  mkdir -p "${dest}"

  local name commit
  local -a names=()
  while read -r name; do
    names+=("${name}")
    if [[ -n "${sync}" ]]; then
      commit="$(pinned "${name}" "${sync}")"
    else
      commit="$(git ls-remote "${ORG_URL}/${name}.git" refs/heads/main \
        | cut -f 1)"
    fi
    # The image build mounts these checkouts, and a changed mount misses the
    # build cache, so a checkout already at the commit stays as it is.
    local head
    head="$(git -C "${dest}/${name}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${head}" != "${commit}" ]]; then
      rm -rf "${dest:?}/${name}"
      git init --quiet "${dest}/${name}"
      git -C "${dest}/${name}" fetch --quiet --depth 1 \
        "${ORG_URL}/${name}.git" "${commit}"
      git -C "${dest}/${name}" -c advice.detachedHead=false checkout \
        --quiet FETCH_HEAD
    fi
    echo "${name}=${commit}"
  done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${LIST}")

  # Drop checkouts of components that are no longer listed.
  local dir
  for dir in "${dest}"/*; do
    [[ -d "${dir}" ]] || continue
    if ! printf '%s\n' "${names[@]}" | grep -qx "${dir##*/}"; then
      rm -rf "${dir}"
    fi
  done
}

main "$@"
