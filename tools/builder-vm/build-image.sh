#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: build-image.sh [--image-only] [--kernel fedora]

Guest-side image build for `builder-vm.sh image`, run in ~/apex-image inside the
builder VM. The Apex RPM key signs every RPM; nothing is pushed, the image is not
signed, and nothing promotes the lane's lock. G1 runs in the build; after it G4
(qualify.sh local) runs when qualify.sh g4-due says it is due (the image's G4 key differs
from the last pass, or that pass is a week old), then G2 (apex-gnome's tests/shots/run.sh,
twice). Both gates always run, so one run shows both verdicts; the exit status is the
first gate's that failed. G4 fails on any row of _build/qualify/results.md that is not
PASS; after a failure, qualify.sh local-diag runs each G4 unit on its own in
_build/qualify/diag, which records nothing and never changes the verdict. G4's key
goes to _build/qualify/g4-pending.txt, and only the gates record moves it to
_build/g4-passed.txt. When G2 passed and G4 passed or was not due,
_build/gates-passed.txt names the lane lock the image carries, the image, G4's verdict,
and whether the components were pinned or a dev-override; `lane.sh promote` requires it,
and pinned components. Neither record is written when the lane lock moved while the
gates ran.

Every G4 verdict, in every mode, adds a row to _build/qualify/verdicts.tsv: the commit,
the image ID, qualify.sh g4-harness's digest, the verdict, the UTC time, the mode (gate,
image-only, break-glass or t2) and APEX_COMPONENTS.

A qualify-only run (T2, advisory) reruns G4 alone on the built image after a fix to the
harness only, and records and promotes nothing: no gates record, no G4 key (it goes to
_build/qualify-only/). It runs, with tools/builder-vm/t2-enabled committed, only when
all of these hold, and otherwise the full gate run does: the working tree is clean
(git status), the image's own manifest
revision is on origin/main and `git diff` from it to HEAD touches only the harness, CI,
the runner, docs or the dev tools (lib.sh, image/, components.lock, Cargo.*, a build
script: the full gate); the last verdicts.tsv row of the image is a FAIL of a gate or t2
run with pinned components, and its harness digest is not HEAD's; the image is the one
G2 last ran on, or the last gate row's; it is under 72 hours old. _build/plan.txt names
the plan. After a failure it runs qualify.sh local-diag too.

APEX_CI_MODE (ci-build's mode) overrides the choice: daily and gate run the full gate,
gate with G4 due whatever its last pass (g4-due reads an empty record, /dev/null); g4
runs qualify-only and exits 2 when its conditions fail. Empty is the choice above.

tools/components.sh fetch and env run before the first build step: each RPM is built
from its pinned component (the apex RPM from apex-system, apex-desktop from
apex-desktop, libfprint from apex-kernel, the lane's recipes from APEX_LANE_RECIPES).

Signed RPMs of pinned components (APEX_COMPONENTS=pinned) are cached in
~/apex-rpm-cache/fedora-N/entries/COMPONENT/ENTRY (APEX_RPM_CACHE moves the root): outside
the checkout and _build, so no build container reaches them. A dev-override build takes
no key and neither reads nor writes the cache. ENTRY hashes the component's own content
key (rpms.sh key, libfprint.sh key, run in its fedora:45 with git-core), the fedora:45
digest, lane.sh's tool id, RPM-GPG-KEY-apex and the build's environment, all taken
before the first build. A component that gives no valid key is built and never cached.
Each entry has an index beside the entries, written only here: the digests of its
PREIMAGE, SHA256SUMS and CONTENTS, each RPM's NEVRA, and when it was stored. An entry is
reused only when it matches its index, is under 7 days old by it, its PREIMAGE, CONTENTS
and SHA256SUMS hold, the key it states matches (KEY; for libfprint key.txt, the RPM's
version-release with .apexN and manifest.txt's tests=passed), and each RPM is signed by
the committed RPM-GPG-KEY-apex (rpmkeys --checksig, in a scratch rpmdb); anything else
rebuilds. rpms.sh build gets the key and fails if it moved. A set is stored only when
its stated key matches, fedora:45 did not move during the build and the copy matches
SHA256SUMS; a degraded libfprint (exit 3) never is. Each component keeps its 3 newest
entries, and the oldest entries this build does not use go until the cache's disk keeps
30 GiB free after storing; when that cannot be reached, nothing is stored. A store that
died leaves ENTRY.tmp, which the next build deletes first.

--image-only reuses the RPMs and the lane lock of the previous run (for Containerfile
or image/ changes), and only says whether G4 is due.

The kernel pair's source artifact (pair.sh's source set, checked with source-check.sh, as an
OCI layout) goes to _build/image/sources when the lane lock has a pair; nothing pushes it.

--kernel fedora builds the break-glass image (just image KERNEL=fedora, ADR 0015):
Fedora's kernel, with the kernel pair's rpm lines left out of the image's lock
(degraded=nvidia). Its gates run, but nothing is recorded, so it never promotes.

APEX_FEDORA=46 builds the next lane from image/fedora/46.env: the components in its
REPOS_BASE, the lane in ~/apex-store/next, _build/next, localhost/apex:46. It gates on
G1 only and records nothing, so it never promotes; image.sh never pushes it.
EOF
}

# shellcheck disable=SC2016 # lib.sh's helpers, run by a child shell of this checkout
lib() { bash -c '. .github/scripts/lib.sh && "$@"' lib "$@"; }

# A next release (APEX_FEDORA=46) has its own store, tag and fedora (lib.sh apex_store).
FEDORA=registry.fedoraproject.org/fedora:45
STORE=${APEX_STORE:-$HOME/apex-store}
IMAGE=localhost/apex:build
BUILD=_build
if [[ ${APEX_FEDORA:-45} != 45 ]]; then
    STORE+=/next
    IMAGE=localhost/apex:$APEX_FEDORA
    BUILD=_build/next
fi
readonly LANE_LOCK=$STORE/rpms.lock.next IMAGE BUILD
# Outside the checkout and _build, which the component containers mount: only this host script writes it.
readonly CACHE_ROOT=${APEX_RPM_CACHE:-$HOME/apex-rpm-cache}/fedora-${APEX_FEDORA:-45}
readonly RPM_CACHE=$CACHE_ROOT/entries CACHE_INDEX=$CACHE_ROOT/index
readonly APEX_RPM_KEY=image/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex
readonly CACHE_KEEP=3 CACHE_MIN_FREE_KIB=$((30 * 1024 * 1024)) CACHE_MAX_AGE_SECONDS=$((7 * 24 * 3600))
readonly GATES_PASSED=_build/gates-passed.txt
readonly G2_RESULT=_build/g2/latest/result.txt
readonly G2_FIRST_RUN=_build/g2/latest/run-1
readonly G2_EXCERPT_LINES=80 G2_EXCERPT_WIDTH=400
readonly G4_KEY=_build/image/g4-key.txt
readonly G4_RECORD=_build/g4-passed.txt
readonly G4_PENDING=_build/qualify/g4-pending.txt
readonly G4_VERDICT_FILE=_build/image/g4-verdict.txt
readonly G4_DIAG=_build/qualify/diag
readonly VERDICTS=_build/qualify/verdicts.tsv
readonly PLAN_FILE=_build/plan.txt
readonly T2_ENABLED=tools/builder-vm/t2-enabled
readonly T2_DIR=_build/qualify-only
readonly T2_MAX_AGE_SECONDS=$((72 * 3600))
readonly G2_RUNS_PER_BUILD=2
readonly G4_NOT_DUE=3

G4_VERDICT=
# lane.sh's tool id, an input of every cache entry; the entry and fedora:45 digest of this component.
LANE_TOOL='' CACHE_ENTRY='' CACHE_DIGEST=''

# Each component builds its own RPMs, in its checkout, as root in a fresh fedora:45. It sees its
# checkout and the /build/... directory it is given, never the rest of _build: others' sources and RPMs.
in_component() {
    local src=$1 rc=0 a
    local -a mounts=(-v "$src:/component:z")
    shift
    for a in "$@"; do
        [[ $a == /build/* ]] || continue
        [[ $a != *..* ]] || { echo "in_component: $a leaves /build" >&2; return 2; }
        mkdir -p -- "$PWD/$BUILD/${a#/build/}"
        mounts+=(-v "$PWD/$BUILD/${a#/build/}:$a:z")
    done
    sudo podman run --rm --pull=newer "${mounts[@]}" -w /component \
        "${COMPONENT_ENV[@]}" "$FEDORA" "$@" || rc=$?
    sudo chown -R "$(id -u):$(id -g)" -- "$src"
    return "$rc"
}
COMPONENT_ENV=()

use_components() {
    [[ -f components.lock ]] || { echo "no components.lock in $PWD" >&2; return 1; }
    echo "== components (components.lock)"
    tools/components.sh fetch
    eval "$(tools/components.sh env)"
}

# After the container exits, so the Apex RPM key never meets a build script.
sign_rpms() {
    local dir=$1
    sudo chown -R "$(id -u):$(id -g)" -- "$dir"
    tools/builder-vm/lane.sh sign "$dir"/*.rpm
    (cd "$dir" && sha256sum -- *.rpm >SHA256SUMS)
}

# shellcheck disable=SC2016 # the container's sh expands these
readonly GIT_FIRST='command -v git >/dev/null || dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install git-core >/dev/null || exit 97; exec "$0" "$@"'
# NAME SRC SCRIPT: the component's content key from its own script, in a fedora:45 with git; or nothing.
component_key() {
    local name=$1 key rc=0
    key=$(in_component "$2" sh -c "$GIT_FIRST" "$3" key | tail -n 1) || rc=$?
    if ((rc != 0)); then
        echo "rpm-cache: $name gives no key (exit $rc); not cached"
    elif [[ ! $key =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then
        echo "rpm-cache: $name gives no key ('${key:0:40}' is not one); not cached"
    else
        printf '%s\n' "$key"
    fi
}

cache_note() { echo "rpm-cache: $*" >&2; }
fedora_digest() { sudo podman image inspect --format '{{.Digest}}' "$FEDORA"; }
free_kib() { df -Pk -- "$1" | awk 'NR == 2 { print $4 }'; }

# ENTRY: its index file, the facts it was stored with.
cache_index() { printf '%s/%s\n' "$CACHE_INDEX" "${1#"$RPM_CACHE"/}"; }
drop_entry() { rm -rf -- "$1" && rm -f -- "$(cache_index "$1")"; }

# DIR: the digests of an entry's inputs and lists, and each RPM's NEVRA, as its index binds them.
index_facts() {
    local f nevra
    printf 'preimage %s\nsums %s\ncontents %s\n' "$(sha256_of "$1/PREIMAGE")" "$(sha256_of "$1/SHA256SUMS")" \
        "$(sha256_of "$1/CONTENTS")"
    for f in "$1"/*.rpm; do
        nevra=$(rpm -qp --queryformat '%{name} %{epochnum}:%{version}-%{release}.%{arch}' -- "$f") || return 1
        printf 'rpm %s %s\n' "${f##*/}" "$nevra"
    done
}

# ENTRY CREATED: its index, written by this script alone, from the entry as stored.
write_index() {
    local idx facts
    idx=$(cache_index "$1")
    facts=$(index_facts "$1") && mkdir -p -- "$(dirname -- "$idx")" &&
        printf '%s\ncreated %s\n' "$facts" "$2" >"$idx.tmp" && mv -- "$idx.tmp" "$idx"
}

by_age() { # DIR DEPTH: its directories at DEPTH, newest first
    find "$1" -mindepth "$2" -maxdepth "$2" -type d ! -name '*.tmp' -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | cut -d' ' -f2-
}

# What a component's RPMs depend on besides its key: an entry is named by the hash of all of it.
cache_preimage() { # NAME KEY DIGEST
    printf 'apex rpm-cache 1\ncomponent %s\nkey %s\nfedora %s@%s\nlane-tool %s\napex-key %s\nenv %s\n' \
        "$1" "$2" "$FEDORA" "$3" "$LANE_TOOL" "$(sha256_of "$APEX_RPM_KEY")" "${COMPONENT_ENV[*]}"
}

# NAME KEY: the entry's path and its preimage's digest, or nothing when an input is unknown.
cache_entry() {
    local digest
    if [[ -z $LANE_TOOL ]]; then
        LANE_TOOL=$(tools/builder-vm/lane.sh --path) && LANE_TOOL=$(basename -- "$(dirname -- "$LANE_TOOL")") ||
            LANE_TOOL=''
    fi
    digest=$(fedora_digest) || digest=''
    if [[ -z $LANE_TOOL || ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "rpm-cache: $1: lane tool '${LANE_TOOL:-?}' or $FEDORA digest '${digest:-?}' unknown; not cached"
        return 0
    fi
    CACHE_DIGEST=$digest
    CACHE_ENTRY=$RPM_CACHE/$1/$(cache_preimage "$1" "$2" "$digest" | sha256sum | cut -c1-32)
}

in_list() { local x=$1; shift; local y; for y in "$@"; do [[ $x != "$y" ]] || return 0; done; return 1; }
# The entries this run reuses or stores: never pruned by it.
CACHE_KEPT=()

unkept() { local e; while IFS= read -r e; do in_list "$e" "${CACHE_KEPT[@]}" || printf '%s\n' "$e"; done; }

# NAME DIR KEY: the component's key that DIR's RPMs were built from, stated and held.
key_holds() {
    local name=$1 dir=$2 key=$3 kt want vr
    if [[ $name != libfprint ]]; then
        [[ $(cat "$dir/KEY" 2>/dev/null) == "$key" ]] || { cache_note "${dir}: KEY is not $key"; return 1; }
        return 0
    fi
    # libfprint.sh key prints build.sh's key.txt as an OCI tag; the RPM is its NVR with .apexN.
    kt=$(cat "$dir/key.txt" 2>/dev/null) || { cache_note "$dir: no key.txt"; return 1; }
    [[ $(oci_tag "$kt") == "$key" ]] ||
        { cache_note "$dir: key.txt $kt is not $key"; return 1; }
    want=${kt%-s*}
    want=${want#libfprint-}
    vr=$(for r in "$dir"/*.rpm; do rpm -qp --queryformat '%{name} %{version}-%{release}\n' -- "$r"; done 2>/dev/null |
        awk '$1 == "libfprint" { print $2 }')
    [[ $vr == "$want".apex* && ${vr#"$want".apex} =~ ^[0-9]+$ ]] ||
        { cache_note "$dir: libfprint ${vr:-?} is not $want.apexN"; return 1; }
    grep -q '^# key=.* tests=passed$' "$dir/manifest.txt" 2>/dev/null ||
        { cache_note "$dir: libfprint's tests did not pass"; return 1; }
}

# SRC DST: the key files a component's build left beside its RPMs.
copy_key_files() { local f; for f in KEY key.txt manifest.txt; do [[ ! -e $1/$f ]] || cp -- "$1/$f" "$2/" || return 1; done; }

# apex-kernel's lib.sh oci_tag: how libfprint.sh key turns build.sh's key into its own.
oci_tag() {
    local t
    t=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
    t=${t:0:128}
    [[ $t =~ ^[A-Za-z0-9_] ]] || t="_${t:0:127}"
    printf '%s\n' "$t"
}

# DIR: its RPMs' room with 30 GiB left, freeing the oldest entries this run does not use.
cache_room() {
    local need avail old size free=0
    local -a olds=()
    if ! { need=$(du -sk -- "$1" | cut -f1) && avail=$(free_kib "$RPM_CACHE"); }; then
        cache_note "cannot measure $RPM_CACHE"
        return 1
    fi
    need=$((need + CACHE_MIN_FREE_KIB))
    ((avail < need)) || return 0
    mapfile -t olds < <(by_age "$RPM_CACHE" 2 | unkept | tac)
    for old in "${olds[@]}"; do
        size=$(du -sk -- "$old" | cut -f1) || size=0
        free=$((free + size))
    done
    if ((avail + free < need)); then
        cache_note "$((avail / 1048576)) GiB free, $((free / 1048576)) GiB in older entries: under 30 GiB after storing; not stored"
        return 1
    fi
    for old in "${olds[@]}"; do
        ((avail < need)) || break
        cache_note "under 30 GiB free; dropping ${old#"$RPM_CACHE"/}"
        drop_entry "$old"
        avail=$(free_kib "$RPM_CACHE") || return 1
    done
    ((avail >= need))
}

# NAME DIR KEY: a copy of DIR's signed RPMs and key files, under the entry cache_entry named.
cache_rpms() {
    local name=$1 dir=$2 key=$3 entry=$CACHE_ENTRY old created
    local tmp=$entry.tmp
    key_holds "$name" "$dir" "$key" || return 1
    [[ $(fedora_digest) == "$CACHE_DIGEST" ]] || { cache_note "$FEDORA moved during the build"; return 1; }
    while IFS= read -r old; do
        cache_note "dropping ${old#"$RPM_CACHE"/}, beyond the $CACHE_KEEP newest of $name"
        drop_entry "$old"
    done < <(by_age "$RPM_CACHE/$name" 1 | unkept | tail -n +"$CACHE_KEEP")
    cache_room "$dir" || return 1
    if ! { rm -rf -- "$tmp" && mkdir -p -- "$tmp" &&
        cp -- "$dir"/*.rpm "$dir/SHA256SUMS" "$tmp/" &&
        (cd "$tmp" && sha256sum --quiet --strict -c SHA256SUMS) &&
        copy_key_files "$dir" "$tmp" &&
        cache_preimage "$name" "$key" "$CACHE_DIGEST" >"$tmp/PREIMAGE" &&
        (cd "$tmp" && sha256sum -- * >CONTENTS) &&
        drop_entry "$entry" && mv -- "$tmp" "$entry"; }; then
        cache_note "cannot write $tmp"
        rm -rf -- "$tmp"
        return 1
    fi
    created=$(date +%s)
    write_index "$entry" "$created" || { cache_note "cannot index $entry; not stored"; drop_entry "$entry"; return 1; }
    CACHE_KEPT+=("$entry")
    echo "rpm-cache: stored $name $key as ${entry#"$RPM_CACHE"/}"
}

# NAME DIR KEY: DIR from the entry, never trusted as stored: its inputs, age and contents, the
# key it states, then each signature by the committed Apex key, which alone is in a scratch rpmdb.
reuse_rpms() {
    local name=$1 dir=$2 key=$3 entry=$CACHE_ENTRY db out rpm created idx facts
    [[ -d $entry ]] || { cache_note "$name $key: no entry yet"; return 1; }
    local at=${entry#"$RPM_CACHE"/}
    idx=$(cache_index "$entry")
    facts=$(index_facts "$entry" 2>/dev/null) || facts=''
    if [[ ! -f $idx || -z $facts || $(grep -v '^created ' "$idx") != "$facts" ]]; then
        cache_note "$at does not match its index; rebuilding"
        return 1
    fi
    [[ $(cat "$entry/PREIMAGE" 2>/dev/null) == "$(cache_preimage "$name" "$key" "$CACHE_DIGEST")" ]] ||
        { cache_note "$at: its inputs differ; rebuilding"; return 1; }
    created=$(sed -n 's/^created //p' "$idx")
    if [[ ! $created =~ ^[0-9]+$ ]] || (($(date +%s) - created >= CACHE_MAX_AGE_SECONDS)); then
        cache_note "$at: older than 7 days, or of no age; rebuilding"
        return 1
    fi
    (cd "$entry" && sha256sum --quiet --strict -c CONTENTS) >/dev/null 2>&1 &&
        [[ $(find "$entry" -mindepth 1 -maxdepth 1 ! -name CONTENTS -printf '%f\n' | sort) == \
            "$(sed 's/^[0-9a-f]* [ *]//' "$entry/CONTENTS" | sort)" ]] ||
        { cache_note "$at does not match its CONTENTS; rebuilding"; return 1; }
    [[ $(find "$entry" -maxdepth 1 -name '*.rpm' -printf '%f\n' | sort) == \
        "$(sed 's/^[0-9a-f]* [ *]//' "$entry/SHA256SUMS" 2>/dev/null | sort)" ]] ||
        { cache_note "$at does not match its SHA256SUMS; rebuilding"; return 1; }
    key_holds "$name" "$entry" "$key" || { cache_note "$at: rebuilding"; return 1; }
    db=$(mktemp -d) || { cache_note "$at: no scratch rpmdb; rebuilding"; return 1; }
    if ! { rpm --dbpath "$db" --initdb && rpmkeys --dbpath "$db" --import "$APEX_RPM_KEY"; }; then
        cache_note "$at: no scratch rpmdb; rebuilding"
        rm -rf -- "$db"
        return 1
    fi
    for rpm in "$entry"/*.rpm; do
        out=$(rpmkeys --dbpath "$db" --checksig -- "$rpm" 2>&1) && [[ $out == *": digests signatures OK" ]] || {
            cache_note "${rpm#"$RPM_CACHE"/} is not signed by $APEX_RPM_KEY ($out); rebuilding"
            rm -rf -- "$db"
            return 1
        }
    done
    rm -rf -- "$db" "$dir.tmp"
    if ! { mkdir -p -- "$dir.tmp" && cp -- "$entry"/*.rpm "$entry/SHA256SUMS" "$dir.tmp/" &&
        copy_key_files "$entry" "$dir.tmp" &&
        (cd "$dir.tmp" && sha256sum --quiet --strict -c SHA256SUMS) && rm -rf -- "$dir" && mv -- "$dir.tmp" "$dir"; }; then
        cache_note "$at: cannot copy to $dir; rebuilding"
        rm -rf -- "$dir.tmp"
        return 1
    fi
    touch -- "$entry"
    CACHE_KEPT+=("$entry")
}

# A store that died left ENTRY.tmp; builds hold the guest's build lock, so none is in use.
cache_sweep() {
    if ! { mkdir -p -- "$RPM_CACHE" "$CACHE_INDEX" &&
        find "$RPM_CACHE" "$CACHE_INDEX" -mindepth 2 -maxdepth 2 -name '*.tmp' -exec rm -rf -- {} +; }; then
        cache_note "cannot sweep $CACHE_ROOT"
    fi
}

declare -A CACHE_KEYS=() CACHE_ENTRIES=()
# NAME SRC SCRIPT: the component's key and entry, all taken before any build so no store prunes an entry this run uses.
resolve_entry() {
    local key
    key=$(component_key "$1" "$2" "$3")
    CACHE_ENTRY=''
    if [[ $key == rpm-cache:* ]]; then
        echo "$key"
        key=''
    fi
    [[ -z $key ]] || cache_entry "$1" "$key"
    CACHE_KEYS[$1]=$key
    CACHE_ENTRIES[$1]=$CACHE_ENTRY
    [[ -z $CACHE_ENTRY ]] || CACHE_KEPT+=("$CACHE_ENTRY")
}

# NAME OUT: whether OUT now holds the component's signed RPMs from its cache entry.
reused() {
    CACHE_ENTRY=${CACHE_ENTRIES[$1]-}
    [[ -n $CACHE_ENTRY ]] && reuse_rpms "$1" "$BUILD/$2" "${CACHE_KEYS[$1]}" || return 1
    echo "$1: the signed RPMs of key ${CACHE_KEYS[$1]}, from the cache"
}

# NAME OUT: OUT's freshly signed RPMs into the component's cache entry, when it has one.
store() {
    CACHE_ENTRY=${CACHE_ENTRIES[$1]-}
    [[ -z $CACHE_ENTRY ]] || cache_rpms "$1" "$BUILD/$2" "${CACHE_KEYS[$1]}" || cache_note "$1 not stored"
}

# NAME SRC OUT: a component's signed RPMs, from its cache entry or built.
component_rpms() {
    local key=${CACHE_KEYS[$1]-}
    reused "$1" "$3" && return 0
    in_component "$2" .github/scripts/rpms.sh build "/build/$3" ${key:+"$key"}
    sign_rpms "$BUILD/$3"
    store "$1" "$3"
}

image_id() { sudo podman image inspect --format '{{.Id}}' "$IMAGE"; }
image_revision() {
    sudo podman run --rm --net=none --entrypoint /usr/bin/cat "$IMAGE" /usr/share/apex/manifest.json | jq -er .revision
}
image_created() { sudo podman image inspect --format '{{.Created.Unix}}' "$IMAGE"; }
git_() { git -c safe.directory="$PWD" "$@"; }
sha256_of() { sha256sum <"$1" | cut -d' ' -f1; }
qualify() { .github/scripts/qualify.sh "$@"; }
run_g2() {
    G2_RUNS=$G2_RUNS_PER_BUILD G2_IMAGE_DIR=$PWD/image G2_REPOS_BASE=$(lib release_arg REPOS_BASE) \
        G2_OUT_DIR=$PWD/_build/g2 "$APEX_GNOME_SRC/tests/shots/run.sh" "$IMAGE"
}
run_g4() { QUALIFY_MEM=3G QUALIFY_SMP=4 QUALIFY_G4_RECORD=$PWD/${1:-$G4_PENDING} qualify local "$IMAGE"; }
# record_g4_pass refuses SKIP and WARN rows; the gate refuses the same.
g4_rows_passed() {
    [[ -s _build/qualify/results.md ]] || return 1
    ! awk -F'|' '{ gsub(/ /, "", $3) } $3 != "PASS" { found = 1 } END { exit !found }' _build/qualify/results.md
}
run_diag() { QUALIFY_MEM=3G QUALIFY_SMP=4 QUALIFY_OUT=$PWD/$G4_DIAG qualify local-diag "$IMAGE"; }
# Written to a file: gate_g4 runs in a subshell of its own, for errexit.
g4_verdict() { printf '%s\n' "$1" >"$G4_VERDICT_FILE"; }

# VERDICT MODE: what a qualify-only run decides from. A missing row only rules one out.
add_verdict() {
    local sha id harness
    sha=$(git_ rev-parse HEAD 2>/dev/null) || sha=-
    id=$(image_id 2>/dev/null) || id=-
    harness=$(qualify g4-harness 2>/dev/null) || harness=-
    mkdir -p "$(dirname "$VERDICTS")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sha" "${id:--}" "${harness:--}" "$1" "$(date -u +%FT%TZ)" "$2" \
        "${APEX_COMPONENTS:-unknown}" >>"$VERDICTS" || echo "G4: no row in $VERDICTS" >&2
}

libfprint_env() {
    COMPONENT_ENV=(-e "GA_REACHED=$(lib ga_reached)" -e "TESTING_INCLUDEPKGS=$(lib testing_includepkgs)")
    # apex-kernel's libfprint build knows only 45's key; a next release names its own.
    [[ $BUILD == _build ]] || COMPONENT_ENV+=(-e "FEDORA_KEY_FPR=$(lib release_arg FEDORA_KEY_FPR)")
}

build_inputs() {
    echo "== the components' keys (rpm-cache)"
    # A key hashes the commit; a dev-override builds its working tree, so only pinned clean clones are cached.
    if [[ ${APEX_COMPONENTS:-} == pinned ]]; then
        cache_sweep
        resolve_entry apex-system "$APEX_SYSTEM_SRC" .github/scripts/rpms.sh
        resolve_entry apex-desktop "$APEX_DESKTOP_SRC" .github/scripts/rpms.sh
        libfprint_env
        resolve_entry libfprint "$APEX_KERNEL_SRC" .github/scripts/libfprint.sh
        COMPONENT_ENV=()
    else
        echo "rpm-cache: components are ${APEX_COMPONENTS:-unknown}, not pinned; nothing is cached or reused"
    fi

    echo "== 1/4 the apex RPM (apex-system) and apex-desktop (apex-desktop)"
    component_rpms apex-system "$APEX_SYSTEM_SRC" rpms/apex
    component_rpms apex-desktop "$APEX_DESKTOP_SRC" rpms/desktop

    echo "== 2/4 libfprint (apex-kernel)"
    local rc=0 reused=0
    libfprint_env
    if reused libfprint libfprint; then
        reused=1
    else
        in_component "$APEX_KERNEL_SRC" .github/scripts/libfprint.sh build /build/libfprint || rc=$?
    fi
    case $rc in
        0)
            if ((!reused)); then
                sign_rpms "$BUILD/libfprint"
                # key_holds checks that key.txt, the RPM's NVR and passed tests match the key.
                store libfprint libfprint
            fi ;;
        3) echo "libfprint: patches do not apply; the image uses Fedora's libfprint (degraded=fingerprint)"
           libfprint_args=() ;;
        *) echo "libfprint: build failed (exit $rc)" >&2; exit "$rc" ;;
    esac
    COMPONENT_ENV=()

    echo "== 3/4 rebuild lane"
    rc=0
    tools/builder-vm/lane.sh build all || rc=$?
    case $rc in
        0) ;;
        3) echo "lane: a family is held, degraded or kept stock; the image takes what $LANE_LOCK records" ;;
        *) echo "lane: failed (exit $rc); $LANE_LOCK is unchanged" >&2; exit "$rc" ;;
    esac
}

build_image() {
    echo "== 4/4 image"
    local -a kernel_args=()
    [[ ${APEX_KERNEL:-} != fedora ]] || kernel_args=(--kernel fedora)
    .github/scripts/image.sh context --rpms-dir "$BUILD/rpms/apex" --desktop-dir "$BUILD/rpms/desktop" \
        "${libfprint_args[@]}" --lane-lock "$LANE_LOCK" "${kernel_args[@]}"
    .github/scripts/image.sh build
    .github/scripts/image.sh inspect
    tools/builder-vm/lane.sh status
    source_artifact
}

# The pair's GPL source, next to the image it was built into; the runner pushes it.
source_artifact() {
    rm -rf "$BUILD/image/sources"
    if [[ ${APEX_KERNEL:-} == fedora ]]; then
        echo "sources: a break-glass image takes no kernel pair, so no source artifact"
        return 0
    fi
    tools/builder-vm/lane.sh sources --lock "$LANE_LOCK" --out "$BUILD/image/sources"
}

# The case logs stay in the builder VM, so vm.yml's log gets each failing case's crash lines and tail.
g2_failure_excerpts() {
    local case
    [[ -s $G2_FIRST_RUN/assert.txt ]] || return 0
    while read -r case; do
        [[ -f $G2_FIRST_RUN/$case.log ]] || continue
        echo "== G2 $case: $(grep -h "^$case exit=" "$G2_FIRST_RUN"/results-*.txt 2>/dev/null | tail -n 1)"
        { grep -nE 'JS ERROR|CRITICAL|crashed with signal|Segmentation fault|== Stack trace|^#[0-9]+ ' \
            "$G2_FIRST_RUN/$case.log" || true; } | head -n 40 | cut -c1-"$G2_EXCERPT_WIDTH"
        echo "-- $case.log, its last $G2_EXCERPT_LINES lines"
        tail -n "$G2_EXCERPT_LINES" "$G2_FIRST_RUN/$case.log" | cut -c1-"$G2_EXCERPT_WIDTH"
    done < <(awk '$1 == "FAIL" { sub(/:$/, "", $2); print $2 }' "$G2_FIRST_RUN/assert.txt" | sort -u)
}

gate_g2() {
    echo "== G2, the headless shell, $G2_RUNS_PER_BUILD runs"
    if ! run_g2; then
        g2_failure_excerpts >&2
        echo "G2 failed (_build/g2/latest): $IMAGE is built, but its lock must not be promoted" >&2
        return 1
    fi
    if [[ $(sed -n 's/^image-id //p' "$G2_RESULT" 2>/dev/null) != "$(image_id)" ]]; then
        echo "G2 passed, but $G2_RESULT names another image than $IMAGE" >&2
        return 1
    fi
}

gate_g4() {
    local image_only=$1 rc=0 last_pass id mode=gate record=$PWD/$G4_RECORD
    ((!image_only)) || mode=image-only
    # Same tag, other kernel: a break-glass row never stands for the pair image's verdict.
    [[ ${APEX_KERNEL:-} != fedora ]] || mode=break-glass
    echo "== G4, when qualify.sh g4-due says it is due"
    if [[ ${APEX_CI_MODE:-} == gate ]]; then
        record=/dev/null
        echo "G4 is due: ci-build gate asks for it, whatever its last pass"
    fi
    qualify g4-key "$IMAGE" >"$G4_KEY" || return
    last_pass=$(QUALIFY_G4_RECORD=$record qualify g4-due "$G4_KEY") || rc=$?
    case $rc in
        0)
            if ((image_only)); then
                g4_verdict due
                add_verdict DUE "$mode"
                echo "G4 is due but not run with --image-only: just vm-qualify, then just vm-image-only, before just pkg-promote"
            elif run_g4 && g4_rows_passed; then
                id=$(image_id)
                g4_verdict "passed for image $id"
                add_verdict PASS "$mode"
            else
                g4_verdict failed
                add_verdict FAIL "$mode"
                echo "G4 failed (_build/qualify/results.md): $IMAGE is built, but its lock must not be promoted" >&2
                return 1
            fi ;;
        "$G4_NOT_DUE")
            g4_verdict "not due: its key passed on $(sed -n 's/^passed-at //p' <<<"$last_pass") for image $(sed -n 's/^image-id //p' <<<"$last_pass")"
            add_verdict NOT-DUE "$mode" ;;
        *) return "$rc" ;;
    esac
}

record_gates() {
    local id image_lock lane_lock
    if [[ ${APEX_KERNEL:-} == fedora ]]; then
        echo "break-glass image (KERNEL=fedora): its gates ran, but nothing is recorded, so just pkg-promote refuses it"
        return 0
    fi
    id=$(image_id) || return
    image_lock=$(sed -n 's/^lock-sha256 //p' "$G2_RESULT")
    lane_lock=$(sha256_of "$LANE_LOCK") || return
    if [[ -z $image_lock || $image_lock != "$lane_lock" ]]; then
        echo "the lane lock moved while the gates ran: $IMAGE carries ${image_lock:-no lock}, $LANE_LOCK is now $lane_lock; nothing is recorded (just vm-image again)" >&2
        return 1
    fi
    if [[ -s $G4_PENDING ]]; then mv -f -- "$G4_PENDING" "$G4_RECORD"; fi
    printf 'lock-sha256 %s\nimage-id %s\ng2 passed\ng4 %s\ncomponents %s\n' "$image_lock" "$id" "$G4_VERDICT" \
        "${APEX_COMPONENTS:-unknown}" >"$GATES_PASSED"
    echo "G1 and G2 passed for $IMAGE (image $id); G4 $G4_VERDICT"
    echo "just pkg-promote makes the lane lock it carries rpms.lock"
}

# Each unit of G4 on its own after a G4 failure, so one run shows every failing row. It
# records nothing, and never changes the gates' verdict.
diagnose_g4() {
    echo "== G4 diagnosis (qualify.sh local-diag, records nothing)"
    if run_diag; then
        echo "local-diag: every unit passed ($G4_DIAG/diag.md)"
    else
        echo "local-diag: exit $? ($G4_DIAG/diag.md); the gates' verdict stands" >&2
    fi
}

# G4 first: it fails far more often than G2. Both always run, each in its own errexit
# subshell, which || around gates would switch off: call it bare.
gates() {
    local image_only=$1 g4=0 g2=0 rec=0 rc
    mkdir -p _build/qualify
    rm -rf -- "$G4_PENDING" "$G4_VERDICT_FILE" "$G4_DIAG"
    set +e
    (set -e; gate_g4 "$image_only")
    g4=$?
    (set -e; gate_g2)
    g2=$?
    set -e
    G4_VERDICT=
    if [[ -s $G4_VERDICT_FILE ]]; then G4_VERDICT=$(cat -- "$G4_VERDICT_FILE"); fi
    if ((g4 == 0)) && [[ -z $G4_VERDICT || $G4_VERDICT == failed ]]; then
        echo "gate_g4 returned 0 with the verdict '$G4_VERDICT'" >&2
        g4=1
    fi
    [[ $G4_VERDICT != failed ]] || diagnose_g4
    if ((g4 == 0 && g2 == 0)) && [[ $G4_VERDICT != due ]]; then
        set +e
        (set -e; record_gates)
        rec=$?
        set -e
    fi
    rm -f -- "$G4_PENDING"
    for rc in "$g4" "$g2" "$rec"; do
        ((rc == 0)) || return "$rc"
    done
}

# What a qualify-only run may follow: the harness, CI, the runner, docs, the dev tools.
# lib.sh is image.sh's too.
harness_path() {
    case $1 in
        .github/scripts/qualify.sh | .github/scripts/qualify-allowed-failures.txt) ;;
        .github/scripts/selftest.sh | .github/scripts/contracts.sh | .github/workflows/*) ;;
        tools/runner/*) ;;
        image/* | crates/*) return 1 ;;
        *.md) ;;
        tools/builder-vm/ci-build.sh | tools/builder-vm/builder-vm.sh | tools/builder-vm/desktop-*.sh) ;;
        tools/builder-vm/shell-dev*.sh | tools/builder-vm/provision.sh | tools/builder-vm/publish-image.sh) ;;
        tools/builder-vm/install-cosign.sh | tools/builder-vm/firmware.sh | tools/builder-vm/lane-rehearsal.sh) ;;
        tools/builder-vm/rehearsal/* | "$T2_ENABLED") ;;
        *) return 1 ;;
    esac
}

harness_only_diff() {
    local path paths
    paths=$(git_ diff --no-renames --name-only "$1" HEAD) || return 1
    [[ -n $paths ]] || { echo "HEAD is the image's revision: nothing to qualify again"; return 1; }
    while IFS= read -r path; do
        harness_path "$path" || { echo "$path changed since the image's revision"; return 1; }
    done <<<"$paths"
}

last_verdict() { awk -F'\t' -v id="$1" '$2 == id { row = $0 } END { if (row == "") exit 1; print row }' "$VERDICTS" 2>/dev/null; }
last_gate_image() { awk -F'\t' '$6 == "gate" { id = $2 } END { print id }' "$VERDICTS" 2>/dev/null; }

# Every condition of a qualify-only run: a condition not met, or any helper that fails,
# means the full gate run. It prints why not.
t2_plan() {
    local id rev row blob verdict mode components harness created dirty
    [[ -f $T2_ENABLED ]] || { echo "qualify-only is off: no $T2_ENABLED"; return 1; }
    [[ $BUILD == _build && -z ${APEX_KERNEL:-} ]] || { echo "only the 45 image with its kernel pair"; return 1; }
    [[ -z $(compgen -v APEX_SRC_) ]] || { echo "a dev-override component (APEX_SRC_*)"; return 1; }
    # git diff below sees commits only, and snapshot.sh runs on the full gate's path alone.
    dirty=$(git_ status --porcelain) || { echo "git status failed"; return 1; }
    [[ -z $dirty ]] || { echo "the working tree has changes no commit holds: $(head -n 1 <<<"$dirty")"; return 1; }
    id=$(image_id) && [[ -n $id ]] || { echo "no $IMAGE"; return 1; }
    rev=$(image_revision) && [[ $rev =~ ^[0-9a-f]{40}$ ]] || { echo "$IMAGE has no manifest revision"; return 1; }
    git_ merge-base --is-ancestor "$rev" origin/main || { echo "its revision $rev is not on origin/main"; return 1; }
    harness_only_diff "$rev" || return 1
    row=$(last_verdict "$id") || { echo "image $id has no G4 verdict in $VERDICTS"; return 1; }
    IFS=$'\t' read -r _ _ blob verdict _ mode components <<<"$row"
    [[ $verdict == FAIL && ($mode == gate || $mode == t2) && $components == pinned ]] ||
        { echo "image $id's last G4 verdict is $verdict ($mode, $components), not a pinned gate or t2 FAIL"; return 1; }
    harness=$(qualify g4-harness) && [[ -n $harness ]] || { echo "no harness digest (qualify.sh g4-harness)"; return 1; }
    [[ $harness != "$blob" ]] || { echo "the harness is the one that failed on image $id"; return 1; }
    [[ $id == "$(sed -n 's/^image-id //p' "$G2_RESULT" 2>/dev/null)" || $id == "$(last_gate_image)" ]] ||
        { echo "image $id is neither G2's last nor the last gate run's"; return 1; }
    created=$(image_created) && [[ $created =~ ^[0-9]+$ ]] || { echo "no creation time for $IMAGE"; return 1; }
    (($(date +%s) - created < T2_MAX_AGE_SECONDS)) || { echo "image $id is 72 hours old or more"; return 1; }
}

# G4 alone on the built image, after a harness fix: advisory, so nothing is recorded.
qualify_only() {
    local rc
    use_components
    [[ ${APEX_COMPONENTS:-} == pinned ]] || { echo "qualify-only: components ${APEX_COMPONENTS:-unknown}" >&2; return 1; }
    mkdir -p _build/qualify "$T2_DIR"
    rm -rf -- "$G4_DIAG" "$T2_DIR/g4-pending.txt"
    echo "== G4 (qualify-only, advisory): qualify.sh local on $IMAGE"
    set +e
    (set -e; run_g4 "$T2_DIR/g4-pending.txt" && g4_rows_passed)
    rc=$?
    set -e
    rm -f -- "$T2_DIR/g4-pending.txt"
    if ((rc == 0)); then
        add_verdict PASS t2
        echo "qualify-only: G4 passed on image $(image_id); the full gate run decides, and records"
        return 0
    fi
    add_verdict FAIL t2
    echo "qualify-only: G4 failed (_build/qualify/results.md); it records nothing and promotes nothing" >&2
    diagnose_g4
    return "$rc"
}

main() {
    local image_only=0 why=
    APEX_KERNEL=
    while (($#)); do
        case $1 in
            --image-only) image_only=1; shift ;;
            --kernel)
                [[ ${2:-} == fedora ]] || { usage >&2; exit 2; }
                APEX_KERNEL=fedora
                shift 2
                ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done

    cd "$HOME/apex-image"
    if [[ ${APEX_FEDORA:-45} != 45 ]]; then
        FEDORA=$(lib release_arg REPOS_BASE) || exit 2
        echo "== the next lane: Fedora $APEX_FEDORA, $IMAGE, $LANE_LOCK; nothing promotes or pushes"
    fi
    rm -f -- "$GATES_PASSED" "$PLAN_FILE"
    if [[ $BUILD == _build ]]; then
        mkdir -p _build
        case ${APEX_CI_MODE:-} in
            '' | g4) ;;
            daily | gate) why="ci-build $APEX_CI_MODE: the full gate run" ;;
            *) echo "APEX_CI_MODE=$APEX_CI_MODE: not daily, gate or g4" >&2; exit 2 ;;
        esac
        if [[ -z $why ]] && ((!image_only)) && why=$(t2_plan 2>&1); then
            echo "== plan: qualify-only (advisory)"
            echo qualify-only >"$PLAN_FILE"
            qualify_only
            return
        fi
        if [[ ${APEX_CI_MODE:-} == g4 ]]; then
            echo "ci-build g4: qualify-only refused: ${why:---image-only}" >&2
            exit 2
        fi
        echo "== plan: gate (G4 first)"
        echo "plan: ${why:-a full run}"
        echo gate >"$PLAN_FILE"
    fi
    # Every full run starts from empty outputs: the containers write them as root, and a
    # stale RPM next to a new one would let dnf pick either.
    if ((!image_only)); then
        sudo rm -rf "$BUILD/rpms" "$BUILD/libfprint"
    elif [[ ! -s $BUILD/rpms/apex/SHA256SUMS || ! -s $BUILD/rpms/desktop/SHA256SUMS ]]; then
        echo "--image-only needs the RPMs of an earlier full run in $BUILD/rpms" >&2
        exit 1
    elif [[ ! -s $LANE_LOCK ]]; then
        echo "--image-only needs the lane's $LANE_LOCK of an earlier full run (or just pkg-build)" >&2
        exit 1
    fi
    mkdir -p _build/image

    # apex-lane and image.sh build from git HEAD, not from the working tree.
    tools/builder-vm/snapshot.sh
    use_components

    libfprint_args=(--libfprint-dir "$BUILD/libfprint")
    if ((image_only)); then
        echo "== 1/4 to 3/4 skipped (--image-only): reusing $BUILD/rpms, $BUILD/libfprint and $LANE_LOCK"
        [[ -d $BUILD/libfprint && -n $(ls -A "$BUILD/libfprint") ]] || libfprint_args=()
    else
        build_inputs
    fi
    build_image

    if [[ $BUILD != _build ]]; then
        echo "build-image: the next lane gates on G1 only and records nothing; state in ~/apex-image/_build/next"
        return 0
    fi
    gates "$image_only"
    echo "build-image: done; state in ~/apex-image/_build/image"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
