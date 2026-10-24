#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: lane-absorb-report.sh [PKG...]

ROADMAP S1b's exit, checked early: does each lane recipe's Apex series still apply, at
fuzz 0, to the newest Fedora 45 build of its package? For every recipe of
APEX_LANE_RECIPES (default: the pinned components), or only PKG..., in one fresh
container of image/Containerfile's REPOS_BASE:

  1. the newest SRPM from fedora + updates (stable) and, when newer, from
     updates-testing, checked with rpmkeys -K against the image's Fedora key;
  2. Fedora's own %prep (rpmbuild -bp), as the lane's pristine tree;
  3. each series patch in order with git apply, as %autosetup -S git does: "applies".
     A patch git apply refuses is tried with patch --fuzz=2: "fuzz" when that takes it
     (the export needs a rebase, but no hunk moved), else "fails", with the hunks;
     the patches after a failure are not tried.

For gnome-shell it also reports mutter, the pin: Fedora's spec's mutter-devel
requirement against the newest mutter-devel of the same repositories.

The report is _build/absorb/report.md, with each run's log in _build/absorb/logs/.
Exit 0 when every series applies at fuzz 0, 3 when one does not, 1 on an error.
APEX_CONTAINER picks the runtime (default podman, as root).
EOF
    exit 2
}

readonly FUZZ=2
readonly FEDORA_KEY=/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-45-primary
readonly FEDORA_KEY_FPR=4F50A6114CD5C6976A7F1179655A4B02F577861E
readonly PREP_TOOLS=(rpm-build git-core patch gnupg2 tar xz bzip2 gzip unzip)

# ---- in the container -----------------------------------------------------------------

newest_srpm() {
    dnf5 -q repoquery "${@:2}" --latest-limit=1 --arch=src --qf '%{name}-%{version}-%{release}\n' "$1" 2>/dev/null | tail -n 1
}

prep_tree() {
    local srpm=$1 top=$2 spec
    rpm -i --define "_topdir $top" "$srpm" >&2 || return 1
    spec=$(find "$top/SPECS" -name '*.spec' | head -n 1)
    rpmbuild -bp --nodeps --define "_topdir $top" "$spec" >&2 || return 1
    find "$top/BUILD" -mindepth 2 -maxdepth 2 -type d ! -name BUILDROOT ! -name SPECPARTS | head -n 1
}

apply_series() {
    local tree=$1 recipe=$2 p out verdict=applies detail=() note n=0
    while IFS= read -r p; do
        [[ -n $p && $p != \#* ]] || continue
        n=$((n + 1))
        if out=$(cd "$tree" && git apply -p1 "$recipe/patches/$p" 2>&1); then
            continue
        fi
        if note=$(cd "$tree" && patch -p1 --fuzz="$FUZZ" --no-backup-if-mismatch -s <"$recipe/patches/$p" 2>&1); then
            verdict=fuzz
            detail+=("$p: git apply refuses ($(head -n 1 <<<"$out")); patch takes it${note:+: $(paste -sd' ' <<<"$note")}")
            continue
        fi
        printf 'fails\t%s: %s; patch: %s (later patches not tried)\n' "$p" \
            "$(grep -m 3 '^error:' <<<"$out" | paste -sd' ')" "$(grep -m 3 FAILED <<<"$note" | paste -sd' ')"
        return
    done <"$recipe/series"
    printf '%s\t%s patch(es)%s\n' "$verdict" "$n" "$( ((${#detail[@]} == 0)) || { printf '; ' && IFS='|' && printf '%s' "${detail[*]}"; })"
}

mutter_pin() {
    local spec=$1 want newest
    want=$(rpmspec -q --buildrequires "$spec" 2>/dev/null | sed -n 's/^mutter-devel >= \(.*\)/\1/p' | head -n 1)
    newest=$(dnf5 -q repoquery "${@:2}" --latest-limit=1 --arch=x86_64 --qf '%{version}-%{release}\n' mutter-devel 2>/dev/null | tail -n 1)
    if [[ -z $want || -z $newest ]]; then
        printf 'unknown\tthe spec asks for mutter-devel >= %s; the newest mutter-devel is %s\n' "${want:-?}" "${newest:-none}"
    elif [[ $(rpm --eval "%{lua: print(rpm.vercmp('$newest', '$want'))}") -ge 0 ]]; then
        printf 'applies\tmutter-devel %s meets the spec'"'"'s >= %s\n' "$newest" "$want"
    else
        printf 'fails\tmutter-devel %s is below the spec'"'"'s >= %s\n' "$newest" "$want"
    fi
}

in_container() {
    local out=$1 recipe name variant nevr last='' srpm top tree result
    local -a repos srcrepos
    shift
    local fpr
    dnf5 -y -q --setopt=install_weak_deps=False install "${PREP_TOOLS[@]}" >/dev/null 2>&1 ||
        { echo "absorb: dnf cannot install the prep tools" >&2; return 1; }
    fpr=$(gpg --show-keys --with-colons "$FEDORA_KEY" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    [[ $fpr == "$FEDORA_KEY_FPR" ]] || { echo "absorb: $FEDORA_KEY is not the pinned Fedora 45 key ($fpr)" >&2; return 1; }
    rpmkeys --import "$FEDORA_KEY"
    mkdir -p "$out/logs" "$out/srpms"
    for recipe in "$@"; do
        name=$(sed -n 's/^srpm=//p' "$recipe/pkg.env")
        last=''
        for variant in stable testing; do
            repos=(--repo=fedora --repo=updates)
            [[ $variant == stable ]] || repos+=(--repo=updates-testing)
            srcrepos=("${repos[@]/%/-source}")
            nevr=$(newest_srpm "$name" "${srcrepos[@]}")
            if [[ -z $nevr ]]; then
                printf '%s\t%s\t-\tunknown\tno SRPM of %s in these repositories\n' "${recipe##*/}" "$variant" "$name"
                continue
            fi
            if [[ $nevr == "$last" ]]; then
                printf '%s\t%s\t%s\tsame\tupdates-testing has nothing newer\n' "${recipe##*/}" "$variant" "$nevr"
                continue
            fi
            last=$nevr
            dnf5 -q download --destdir "$out/srpms" "${srcrepos[@]}" "$nevr.src" \
                >"$out/logs/${recipe##*/}-$variant.log" 2>&1
            srpm=$out/srpms/$nevr.src.rpm
            if ! rpmkeys -K "$srpm" >>"$out/logs/${recipe##*/}-$variant.log" 2>&1; then
                printf '%s\t%s\t%s\tunknown\tthe SRPM does not verify (logs/%s-%s.log)\n' "${recipe##*/}" "$variant" "$nevr" "${recipe##*/}" "$variant"
                continue
            fi
            top=$(mktemp -d)
            if ! tree=$(prep_tree "$srpm" "$top" 2>>"$out/logs/${recipe##*/}-$variant.log") || [[ -z $tree ]]; then
                printf '%s\t%s\t%s\tunknown\tFedora'"'"'s %%prep failed or made no source tree (logs/%s-%s.log)\n' "${recipe##*/}" "$variant" "$nevr" "${recipe##*/}" "$variant"
                rm -rf "$top"
                continue
            fi
            result=$(apply_series "$tree" "$recipe")
            printf '%s\t%s\t%s\t%s\n' "${recipe##*/}" "$variant" "$nevr" "$result"
            if grep -qx 'pin=mutter' "$recipe/pkg.env"; then
                printf 'mutter (pin)\t%s\t-\t%s\n' "$variant" "$(mutter_pin "$(find "$top/SPECS" -name '*.spec' | head -n 1)" "${repos[@]}")"
            fi
            rm -rf "$top"
        done
    done
}

# ---- on the host ----------------------------------------------------------------------

render() {
    local rows=$1 report=$2
    {
        printf '# Lane absorption report\n\n'
        printf '%s, REPOS_BASE %s. "applies": every patch takes git apply (fuzz 0); "fuzz": patch --fuzz=%s takes what git apply refuses; "fails": neither.\n\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "$FUZZ"
        printf '| Family | Repositories | Newest SRPM | Result | Detail |\n|---|---|---|---|---|\n'
        awk -F'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' "$rows"
    } >"$report"
}

main() {
    if [[ ${1:-} == --in-container ]]; then
        shift
        in_container "$@"
        return
    fi
    [[ ${1:-} != -* ]] || usage
    local checkout base out root recipe rc=0
    local -a roots recipes=() mounts=()
    checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
    # shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
    . "$checkout/.github/scripts/lib.sh"
    if [[ -z ${APEX_LANE_RECIPES:-} ]]; then
        eval "$("$checkout/tools/components.sh" env)"
    fi
    base=$(containerfile_arg REPOS_BASE "$checkout/image/Containerfile")
    is_fedora_pin "$base" || die "image/Containerfile REPOS_BASE '$base' is not a registry.fedoraproject.org digest pin"
    IFS=: read -ra roots <<<"${APEX_LANE_RECIPES:-$checkout}"
    local i=0
    for root in "${roots[@]}"; do
        for recipe in "$root"/packaging/pkgs/*/; do
            recipe=${recipe%/}
            if [[ ! -f $recipe/series ]] || ! grep -q '^source=fedora-srpm' "$recipe/pkg.env" 2>/dev/null; then continue; fi
            if (($#)) && ! printf '%s\n' "$@" | grep -qx "${recipe##*/}"; then continue; fi
            mounts+=(-v "$recipe:/recipes/$i/${recipe##*/}:ro,z")
            recipes+=("/recipes/$i/${recipe##*/}")
            i=$((i + 1))
        done
    done
    ((${#recipes[@]} > 0)) || die "no lane recipe with a series${*:+ named $*} in ${APEX_LANE_RECIPES:-$checkout}"
    out=$checkout/_build/absorb
    rm -rf -- "$out"
    mkdir -p -- "$out"
    log "absorb: ${#recipes[@]} recipe(s) in $base"
    as_root "${APEX_CONTAINER:-podman}" run --rm -v "$checkout/tools/builder-vm/lane-absorb-report.sh:/absorb.sh:ro,z" \
        -v "$out:/out:z" "${mounts[@]}" "$base" bash /absorb.sh --in-container /out "${recipes[@]}" >"$out/rows.tsv" ||
        die "the container failed (rows so far: $out/rows.tsv)"
    as_root chown -R "$(id -u):$(id -g)" -- "$out"
    rm -rf -- "$out/srpms"
    render "$out/rows.tsv" "$out/report.md" "$base"
    cat "$out/report.md"
    ! cut -f4 "$out/rows.tsv" | grep -qv -e '^applies$' -e '^same$' || rc=3
    return "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
