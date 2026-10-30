#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

G4's journal markers against their sources: every journal line a G4 row of qualify.sh
waits for has an entry in qualify-markers.txt, and the source context each entry records
is unchanged in the current Fedora 45 build (fedora + updates; for a lane family, with
apex-gnome's series) or in the apex-gnome checkout APEX_GNOME_SRC. Runs in fedora:45.

  markers.sh      exit 0 when every marker's context is unchanged
EOF
    exit 2
}

(($# == 0)) || usage
require dnf5 rpmbuild patch python3
gnome=$(component_at apex-gnome "$APEX_GNOME_SRC")

# The current Fedora build of each package the markers come from, prepared as rpmbuild does,
# and for a lane family with apex-gnome's series on top: the image ships those lines.
readonly MARKERS=$APEX_ROOT/.github/scripts/qualify-markers.txt
marker_src=$(mktemp -d)
trap 'rm -rf "$marker_src"' EXIT
mapfile -t pkgs < <(sed -n 's/^source: \([^ ]*\) .*/\1/p' "$MARKERS" | sort -u)
for pkg in "${pkgs[@]}"; do
    mkdir -p "$marker_src/$pkg"
    if [[ $pkg == apex-gnome ]]; then
        ln -s "$APEX_GNOME_SRC" "$marker_src/$pkg/tree"
        printf '%s\n' "$gnome" >"$marker_src/$pkg/nvr"
        continue
    fi
    nvr=$(dnf5 -q --repo=fedora --repo=updates repoquery --available --latest-limit=1 \
        --queryformat '%{name}-%{version}-%{release}\n' "$pkg" | head -n 1)
    [[ -n $nvr ]] || die "markers: fedora and updates offer no $pkg"
    retry 3 10 dnf5 -q --repo=fedora-source --repo=updates-source download --source \
        --destdir "$marker_src/$pkg" "$nvr" >/dev/null
    rpmbuild -rp --nodeps --define "_topdir $marker_src/$pkg/top" "$marker_src/$pkg/$nvr.src.rpm" \
        >"$marker_src/$pkg/prep.log" 2>&1 || die "markers: %prep of $nvr failed: $(tail -n 3 "$marker_src/$pkg/prep.log")"
    mapfile -t tops < <(find "$marker_src/$pkg/top/BUILD" -mindepth 2 -maxdepth 2 -type d ! -name SPECPARTS)
    ((${#tops[@]} == 1)) || die "markers: %prep of $nvr left ${#tops[@]} source trees, expected 1"
    series=$APEX_GNOME_SRC/packaging/pkgs/$pkg/series
    if [[ -f $series ]]; then
        while read -r patch; do
            patch -d "${tops[0]}" -p1 -F0 -s --no-backup-if-mismatch <"${series%/*}/patches/$patch" ||
                die "markers: apex-gnome's $patch does not apply to $nvr"
        done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$series")
        nvr+=" with $gnome's series"
    fi
    ln -s "${tops[0]}" "$marker_src/$pkg/tree"
    printf '%s\n' "$nvr" >"$marker_src/$pkg/nvr"
done
markers=$(qualify_markers "$APEX_ROOT/.github/scripts/qualify.sh" "$MARKERS" "$marker_src") ||
    die "markers: see above"
log "markers: $markers"

