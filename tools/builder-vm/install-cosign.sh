#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# builder-vm.sh pipes this into `ssh builder@vm bash -s -- VERSION SHA256`; safe to re-run.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: install-cosign.sh VERSION SHA256

Installs cosign VERSION (vMAJOR.MINOR.PATCH) from github.com/sigstore/cosign's release as
APEX_COSIGN_BIN (default /usr/local/bin/cosign), only when the download's sha256 is
SHA256, the reviewed pin of tools/builder-vm/cosign.env. A binary already there with
that sha256 is kept. Fedora 45 packages no cosign.
USAGE
    exit 2
}

readonly RELEASES=https://github.com/sigstore/cosign/releases/download

main() {
    (($# == 2)) || usage
    local version=$1 sum=$2 bin=${APEX_COSIGN_BIN:-/usr/local/bin/cosign} tmp
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install-cosign: '$version' is no vMAJOR.MINOR.PATCH" >&2; exit 2; }
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || { echo "install-cosign: '$sum' is no lowercase sha256" >&2; exit 2; }
    if [[ -f $bin && $(sha256sum <"$bin" | cut -d' ' -f1) == "$sum" ]]; then
        echo "install-cosign: $bin is already cosign $version"
        return 0
    fi
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064 # expand now: the path is local
    trap "rm -rf '$tmp'" EXIT
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/cosign" "$RELEASES/$version/cosign-linux-amd64" ||
        { echo "install-cosign: cannot download cosign $version" >&2; exit 1; }
    if [[ $(sha256sum <"$tmp/cosign" | cut -d' ' -f1) != "$sum" ]]; then
        echo "install-cosign: the download of cosign $version does not have the pinned sha256 $sum; nothing installed" >&2
        exit 1
    fi
    sudo install -D -m 0755 "$tmp/cosign" "$bin"
    echo "install-cosign: $bin is cosign $version ($sum)"
}

main "$@"
