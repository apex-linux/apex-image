#!/bin/bash
# Runs the linters from pinned container images, so that a laptop and CI use
# the same versions and nothing is installed on the host.
set -euo pipefail

readonly SHELLCHECK="docker.io/koalaman/shellcheck:v0.11.0"
readonly SHFMT="docker.io/mvdan/shfmt:v3.14.1"
readonly HADOLINT="docker.io/hadolint/hadolint:v2.15.1"
readonly MARKDOWNLINT="markdownlint-cli2@0.24.1"

run() {
  podman run --rm --network=none --volume "${PWD}:/src:ro,z" --workdir /src \
    "$@"
}

main() {
  local -a scripts
  mapfile -t scripts < <(git ls-files --cached --others --exclude-standard \
    '*.sh')

  echo "shellcheck: ${#scripts[@]} script(s)"
  run "${SHELLCHECK}" "${scripts[@]}"
  echo "shfmt"
  run "${SHFMT}" --diff -i 2 -ci -bn "${scripts[@]}"
  local -a containerfiles
  mapfile -t containerfiles < <(git ls-files --cached --others \
    --exclude-standard 'Containerfile' '*/Containerfile')
  echo "hadolint: ${#containerfiles[@]} Containerfile(s)"
  run "${HADOLINT}" hadolint "${containerfiles[@]}"
  echo "markdownlint"
  npx --yes "${MARKDOWNLINT}" "**/*.md" "#build" "#node_modules"
}

main "$@"
