#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: lane-rehearsal.sh point|kmod|all

ROADMAP S1c's lane rehearsals in the builder VM, in a scratch store that the lane's own
store and lock never see (APEX_LANE_REHEARSAL=1; a rehearsal's N starts at 9001).

Each starts from a good pair at the COPR build before the pinned one, built with the
rehearsal's own pkg.env (tools/builder-vm/rehearsal/) over the pinned apex-kernel recipe
and promoted, then lets kernel-bump find the point bump and commit it.

  point  the bump builds as a whole pair; its image passes G1 (in the build), and
         publish.sh rehearse pushes it to a throwaway registry and checks its signature
  kmod   the bump built with APEX_PAIR_FAULT=kmod holds on the kmod side with a limit,
         and its image carries held=kernel-cachyos; with APEX_LANE_NOW past the limit it
         becomes a degraded=nvidia set whose image passes G1, and promote takes it only
         with --allow-degraded
  all    both, from one good pair

The image reuses the RPMs of the last just vm-image (_build/rpms, _build/libfprint).
APEX_REHEARSAL_DIR (default ~/apex-rehearsal) holds the store, the recipes and the
image state; all of it is deleted at the end, pass or fail, but logs/ and report.md.
EOF
    exit 2
}

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
readonly checkout
# shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
. "$checkout/.github/scripts/lib.sh"

readonly COPR_API=https://copr.fedorainfracloud.org/api_3
readonly COPR_RESULTS=https://download.copr.fedorainfracloud.org/results
readonly BUILD_LIST_LIMIT=30
readonly FAMILY=kernel-cachyos
readonly REHEARSAL_IMAGE=localhost/apex:rehearsal
readonly LANE_HELD=3
readonly WHOLE_PAIR="^family $FAMILY built ([^ ]+)$"

dir=${APEX_REHEARSAL_DIR:-$HOME/apex-rehearsal}
store=$dir/store recipes=$dir/recipes logs=$dir/logs report=$dir/report.md
image_sh=${APEX_REHEARSAL_IMAGE_SH:-$checkout/.github/scripts/image.sh}
publish_sh=${APEX_REHEARSAL_PUBLISH_SH:-$checkout/.github/scripts/publish.sh}
lane_bin=
good_key=

row() { printf '| %s | %s | %s |\n' "$1" "$2" "$3" >>"$report"; }
pass() { row "$1" PASS "$2"; log "rehearsal: $1: $2"; }
fail() {
    row "$1" FAIL "$2"
    die "rehearsal: $1: $2 (report: $report)"
}

# The scratch tree goes, pass or fail; the logs and the report are the rehearsal's record.
cleanup() {
    local rc=$?
    rm -rf -- "$store" "$recipes" "$dir/image" 2>/dev/null || as_root rm -rf -- "$store" "$recipes" "$dir/image"
    as_root podman rmi -f "$REHEARSAL_IMAGE" >/dev/null 2>&1 || true
    exit "$rc"
}

lane() {
    local step=$1 rc=0
    shift
    (cd -- "$checkout" && "$lane_bin" "$@") >>"$logs/$step.log" 2>&1 || rc=$?
    return "$rc"
}

family_line() { sed -n "s/^family $FAMILY /&/p" "$store/$1" | head -n 1; }
attr() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -n 1; }

fetch() { curl --fail --silent --show-error --location --retry 3 -- "$1"; }

env_value() { sed -n "s/^$2=//p" "$1"; }

major_of() { cut -d. -f1,2 <<<"$1"; }

# The newest COPR build of the pinned major before the pinned one whose chroot succeeded.
previous_srpm() {
    local kernel_env=$1 srpm copr chroot name pinned dist builds pinned_id id version state
    srpm=$(env_value "$kernel_env" srpm) copr=$(env_value "$kernel_env" copr) chroot=$(env_value "$kernel_env" chroot)
    [[ $srpm =~ ^(.+)-0:([^-]+-[^-]+)\.(fc[0-9]+)\.src$ ]] || fail prepare "kernel.env's srpm '$srpm' is not an fc SRPM NEVRA"
    name=${BASH_REMATCH[1]} pinned=${BASH_REMATCH[2]} dist=${BASH_REMATCH[3]}
    builds=$(fetch "$COPR_API/build/list/?ownername=${copr%/*}&projectname=${copr#*/}&packagename=$name&limit=$BUILD_LIST_LIMIT" |
        jq -r '.items[] | select(.source_package.version != null) | "\(.id) \(.source_package.version)"') ||
        fail prepare "cannot read the COPR's build list of $name"
    pinned_id=$(awk -v v="$pinned" '$2 == v { print $1 }' <<<"$builds" | sort -n | tail -n 1)
    [[ -n $pinned_id ]] || fail prepare "the pinned $pinned is not among the COPR's $BUILD_LIST_LIMIT newest builds"
    while read -r id version; do
        if ((id >= pinned_id)) || [[ $version == "$pinned" || $(major_of "$version") != "$(major_of "$pinned")" ]]; then
            continue
        fi
        state=$(fetch "$COPR_API/build-chroot?build_id=$id&chrootname=$chroot" | jq -r '.state') || continue
        if [[ $state == succeeded ]]; then
            printf '%s-0:%s.%s.src\n' "$name" "$version" "$dist"
            return 0
        fi
    done < <(sort -rn <<<"$builds")
    fail prepare "the COPR has no build of $(major_of "$pinned") before the pinned $pinned to start from"
}

# The lane mirrors the SRPM at first sight and checks it against the pinned COPR key.
pin_previous() {
    local kernel_env=$1 srpm=$2 copr chroot file tmp sha tag
    copr=$(env_value "$kernel_env" copr) chroot=$(env_value "$kernel_env" chroot)
    file=${srpm/-0:/-}.rpm
    tmp=$(mktemp)
    fetch "$COPR_RESULTS/$copr/$chroot/Packages/${file:0:1}/$file" >"$tmp" || { rm -f -- "$tmp"; fail prepare "cannot download $file"; }
    sha=$(sha256sum <"$tmp" | cut -d' ' -f1)
    rm -f -- "$tmp"
    [[ $srpm =~ -0:([^-]+)-([0-9]+)\. ]] || fail prepare "$srpm names no CachyOS tag"
    tag=cachyos-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}
    sed -i -e "s|^srpm=.*|srpm=$srpm|" -e "s|^srpm_sha256=.*|srpm_sha256=$sha|" -e "s|^tag=.*|tag=$tag|" "$kernel_env"
}

prepare() {
    local root f previous
    [[ $store != "$HOME/apex-store" ]] || die "APEX_REHEARSAL_DIR puts the store at the lane's own ~/apex-store"
    rm -rf -- "$dir"
    mkdir -p -- "$logs" "$recipes/packaging/pkgs"
    printf '# Lane rehearsal %s\n\n| Step | Result | Detail |\n|---|---|---|\n' "$(date -u +%FT%TZ)" >"$report"
    trap cleanup EXIT
    local -a roots
    IFS=: read -ra roots <<<"${APEX_LANE_RECIPES:-$checkout}"
    for root in "${roots[@]}"; do
        for f in "$root"/packaging/pkgs/*/pkg.env; do
            [[ -f $f ]] || continue
            ! grep -qx "family=$FAMILY" "$f" ||
                fail prepare "$f is the pair's own recipe: the rehearsal's would be a second $FAMILY family"
        done
    done
    [[ -d ${APEX_KERNEL_SRC:-}/packaging/pkgs/kernel ]] || fail prepare "no apex-kernel checkout with packaging/pkgs/kernel (APEX_KERNEL_SRC)"
    cp -a -- "$APEX_KERNEL_SRC/packaging/pkgs/kernel" "$recipes/packaging/pkgs/kernel"
    cp -- "$checkout/tools/builder-vm/rehearsal/pkg.env" "$recipes/packaging/pkgs/kernel/pkg.env"
    previous=$(previous_srpm "$recipes/packaging/pkgs/kernel/kernel.env")
    pin_previous "$recipes/packaging/pkgs/kernel/kernel.env" "$previous"
    git -C "$recipes" init -q
    git -C "$recipes" config user.name 'Apex lane rehearsal'
    git -C "$recipes" config user.email 'rehearsal@localhost'
    git -C "$recipes" add -A
    git -C "$recipes" commit -q -m "rehearsal: the pair at $previous"
    export APEX_STORE=$store APEX_LANE_REHEARSAL=1
    export APEX_LANE_RECIPES=$recipes:${APEX_LANE_RECIPES:-$checkout}
    pass prepare "the good pair's pins at $previous, the COPR build before the pinned one"
}

good_pair() {
    local rc=0 line
    lane good-pair build all || rc=$?
    ((rc == 0 || rc == LANE_HELD)) || fail good-pair "apex-lane build all exited $rc (logs/good-pair.log)"
    line=$(family_line rpms.lock.next)
    [[ $line =~ $WHOLE_PAIR ]] || fail good-pair "rpms.lock.next has '$line', not a whole pair"
    good_key=${BASH_REMATCH[1]}
    lane good-pair promote || fail good-pair "promote failed (logs/good-pair.log)"
    pass good-pair "built and promoted $good_key"
}

kernel_bump() {
    local branch
    lane kernel-bump kernel-bump || fail kernel-bump "apex-lane kernel-bump failed (logs/kernel-bump.log)"
    branch=$(git -C "$recipes" for-each-ref --format='%(refname:short)' 'refs/heads/kernel-bump/*' | head -n 1)
    [[ -n $branch ]] || fail kernel-bump "no point bump was committed (logs/kernel-bump.log)"
    git -C "$recipes" checkout -q "$branch"
    pass kernel-bump "committed $branch unattended"
}

build_image() {
    local step=$1 work=$dir/image/$1
    local -a fp=()
    [[ -z $(find "$checkout/_build/libfprint" -name '*.rpm' -print -quit 2>/dev/null) ]] || fp=(--libfprint-dir _build/libfprint)
    (
        cd -- "$checkout"
        export APEX_WORK=$work APEX_IMAGE=$REHEARSAL_IMAGE
        "$image_sh" context --rpms-dir _build/rpms/apex --desktop-dir _build/rpms/desktop "${fp[@]}" \
            --lane-lock "$store/rpms.lock.next" &&
            "$image_sh" build && "$image_sh" inspect
    ) >>"$logs/$step.log" 2>&1 || fail "$step" "the image did not build or failed G1 (logs/$step.log)"
    # shellcheck disable=SC1091 # image.sh inspect writes it
    (. "$work/image.env" && printf '%s\n%s\n' "${HELD:-}" "${DEGRADED:-}")
}

point() {
    local rc=0 line labels
    lane point build all || rc=$?
    ((rc == 0 || rc == LANE_HELD)) || fail point "apex-lane build all exited $rc (logs/point.log)"
    line=$(family_line rpms.lock.next)
    [[ $line =~ $WHOLE_PAIR ]] || fail point "rpms.lock.next has '$line', not the bump as a whole pair"
    labels=$(build_image point)
    [[ $(sed -n 1p <<<"$labels") != *$FAMILY* && $(sed -n 2p <<<"$labels") != *nvidia* ]] ||
        fail point "the image is held or degraded: $(paste -sd' ' <<<"$labels")"
    pass point "the bump built as a whole pair (${line##* }); its image passed G1"
    (
        cd -- "$checkout"
        APEX_WORK=$dir/image/point APEX_IMAGE=$REHEARSAL_IMAGE APEX_PREVIOUS_BUILD=none "$image_sh" rechunk &&
            "$publish_sh" rehearse "oci:$dir/image/point/oci/apex:latest"
    ) >>"$logs/publish.log" 2>&1 || fail publish "the rechunk or publish.sh rehearse failed (logs/publish.log)"
    pass publish "rechunked and pushed to a throwaway registry, signed, and refused under another key"
}

kmod() {
    local rc=0 line limit now labels
    APEX_PAIR_FAULT=kmod lane kmod-hold build all || rc=$?
    ((rc == LANE_HELD)) || fail kmod-hold "apex-lane build all exited $rc, not $LANE_HELD (logs/kmod-hold.log)"
    line=$(family_line rpms.lock.next)
    [[ $line == "family $FAMILY held $good_key "*" side=kmod reason=kmod: "* ]] ||
        fail kmod-hold "rpms.lock.next has '$line', not a kmod hold of $good_key"
    limit=$(attr limit "$line")
    [[ -n $limit ]] || fail kmod-hold "the hold has no limit: $line"
    labels=$(build_image kmod-hold)
    [[ $(sed -n 1p <<<"$labels") == *$FAMILY* ]] || fail kmod-hold "the image's held label is '$(sed -n 1p <<<"$labels")'"
    pass kmod-hold "held $good_key with side=kmod until $limit; the image carries held=$FAMILY"
    now=$(date -u -d "@$(($(date -u -d "$limit" +%s) + 1))" +%Y-%m-%dT%H:%M:%SZ)
    rc=0
    APEX_PAIR_FAULT=kmod APEX_LANE_NOW=$now lane kmod-limit build all || rc=$?
    ((rc == LANE_HELD)) || fail kmod-limit "apex-lane build all at $now exited $rc, not $LANE_HELD (logs/kmod-limit.log)"
    line=$(family_line rpms.lock.next)
    [[ $line == "family $FAMILY built "*" degraded=nvidia side=kmod "* ]] ||
        fail kmod-limit "rpms.lock.next has '$line' at $now, not a degraded=nvidia set"
    labels=$(build_image kmod-limit)
    [[ $(sed -n 2p <<<"$labels") == *nvidia* ]] || fail kmod-limit "the image's degraded label is '$(sed -n 2p <<<"$labels")'"
    ! lane kmod-limit promote || fail kmod-limit "promote took a degraded=nvidia set without --allow-degraded"
    lane kmod-limit promote --allow-degraded || fail kmod-limit "promote --allow-degraded failed (logs/kmod-limit.log)"
    pass kmod-limit "at $now the kernel went without NVIDIA (degraded=nvidia); its image passed G1; promote needed --allow-degraded"
}

main() {
    local scenario=${1:-}
    case $scenario in point | kmod | all) ;; *) usage ;; esac
    (($# == 1)) || usage
    require git jq curl sha256sum
    [[ -d $checkout/_build/rpms/apex && -d $checkout/_build/rpms/desktop ]] ||
        die "no _build/rpms of an earlier just vm-image: the rehearsal's images reuse them"
    if [[ -z ${APEX_KERNEL_SRC:-} ]]; then
        eval "$("$checkout/tools/components.sh" env)"
    fi
    lane_bin=${APEX_REHEARSAL_LANE:-$("$checkout/tools/builder-vm/lane.sh" --path)}
    prepare
    good_pair
    kernel_bump
    [[ $scenario == kmod ]] || point
    [[ $scenario == point ]] || kmod
    log "rehearsal: every step passed ($report)"
}

main "$@"
