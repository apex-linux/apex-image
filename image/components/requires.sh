#!/bin/bash
# Installs the RPMs that components declare in /usr/share/<component>/
# requires.txt and checks that each declared path exists afterwards. The
# files are input, not shell: a line must be "<rpm-name> <absolute-path-or-
# glob>", with comments after "#", or the build fails before dnf runs.
set -euo pipefail

# shellcheck source=../common/dnf.sh
source /run/common/dnf.sh

readonly NAME_RE='^[A-Za-z0-9._+-]+$'
readonly PATH_RE='^/[A-Za-z0-9._+*?@/-]+$'

fail() {
  echo "requires: $*" >&2
  exit 1
}

main() {
  local -a files=(/usr/share/*/requires.txt)
  if [[ ! -f "${files[0]}" ]]; then
    echo "requires: no component declares packages"
    return 0
  fi

  local -a names=() paths=()
  local file line name path rest
  for file in "${files[@]}"; do
    while IFS= read -r line || [[ -n "${line}" ]]; do
      read -r name path rest <<<"${line%%#*}" || true
      [[ -n "${name:-}" ]] || continue
      if [[ ! "${name}" =~ ${NAME_RE} || ! "${path:-}" =~ ${PATH_RE} ||
        -n "${rest:-}" ]]; then
        fail "${file}: not '<rpm> <path>': ${line}"
      fi
      names+=("${name}")
      paths+=("${path}")
    done <"${file}"
  done

  local libfprint
  libfprint="$(rpm -q libfprint)"
  local -a unique
  mapfile -t unique < <(printf '%s\n' "${names[@]}" | sort -u)
  echo "requires: ${#unique[@]} packages from ${files[*]}"
  dnf_install "${unique[@]}"
  dnf5 clean all
  rm -rf /var/cache/* /var/lib/dnf /var/log/* /var/tmp/*

  local i missing=0
  for i in "${!paths[@]}"; do
    if ! compgen -G "${paths[i]}" >/dev/null; then
      echo "requires: ${names[i]} did not install ${paths[i]}" >&2
      missing=1
    fi
  done
  ((missing == 0)) || fail "declared paths are missing"

  # The patched libfprint must survive fprintd's install (ADR 0002).
  if [[ "$(rpm -q libfprint)" != "${libfprint}" ]]; then
    fail "libfprint changed from ${libfprint} to $(rpm -q libfprint)"
  fi
  echo "requires: all ${#paths[@]} paths present; ${libfprint}"
}

main "$@"
