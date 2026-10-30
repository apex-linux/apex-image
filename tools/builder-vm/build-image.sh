#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: build-image.sh [--image-only] [--kernel fedora]

Guest-side image build for `builder-vm.sh image`, run in ~/apex-image inside the
builder VM. The Apex RPM key signs every RPM; nothing is pushed, the image is not
signed, and nothing promotes the lane's lock. G1 runs in the build, G2 (apex-gnome's
tests/shots/run.sh, twice) after it, and G4 (qualify.sh local) when qualify.sh g4-due
says it is due: the image's G4 key differs from the last pass, or that pass is a week
old. When G2 passed and G4 passed or was not due, _build/gates-passed.txt names the lane
lock the image carries, the image, G4's verdict, and whether the components were pinned
or a dev-override; `lane.sh promote` requires it, and pinned components. The record is
not written when the lane lock moved while the gates ran.

tools/components.sh fetch and env run before the first build step: each RPM is built
from its pinned component (the apex RPM from apex-system, apex-desktop from
apex-desktop, libfprint from apex-kernel, the lane's recipes from APEX_LANE_RECIPES).

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
readonly GATES_PASSED=_build/gates-passed.txt
readonly G2_RESULT=_build/g2/latest/result.txt
readonly G2_FIRST_RUN=_build/g2/latest/run-1
readonly G2_EXCERPT_LINES=80 G2_EXCERPT_WIDTH=400
readonly G4_KEY=_build/image/g4-key.txt
readonly G2_RUNS_PER_BUILD=2
readonly G4_NOT_DUE=3

G4_VERDICT=

# Each component builds its own RPMs, in its checkout, as root in a fresh fedora:45.
in_component() {
    local src=$1 rc=0
    shift
    sudo podman run --rm --pull=newer -v "$src:/component:z" -v "$PWD/$BUILD:/build:z" -w /component \
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

image_id() { sudo podman image inspect --format '{{.Id}}' "$IMAGE"; }
sha256_of() { sha256sum <"$1" | cut -d' ' -f1; }
qualify() { .github/scripts/qualify.sh "$@"; }
run_g2() {
    G2_RUNS=$G2_RUNS_PER_BUILD G2_IMAGE_DIR=$PWD/image G2_REPOS_BASE=$(lib release_arg REPOS_BASE) \
        G2_OUT_DIR=$PWD/_build/g2 "$APEX_GNOME_SRC/tests/shots/run.sh" "$IMAGE"
}
run_g4() { QUALIFY_MEM=3G QUALIFY_SMP=4 qualify local "$IMAGE"; }

build_inputs() {
    echo "== 1/4 the apex RPM (apex-system) and apex-desktop (apex-desktop)"
    in_component "$APEX_SYSTEM_SRC" .github/scripts/rpms.sh build /build/rpms/apex
    sign_rpms "$BUILD/rpms/apex"
    in_component "$APEX_DESKTOP_SRC" .github/scripts/rpms.sh build /build/rpms/desktop
    sign_rpms "$BUILD/rpms/desktop"

    echo "== 2/4 libfprint (apex-kernel)"
    local rc=0
    # apex-kernel's libfprint build knows only 45's key; a next release names its own.
    [[ $BUILD == _build ]] || COMPONENT_ENV+=(-e "FEDORA_KEY_FPR=$(lib release_arg FEDORA_KEY_FPR)")
    in_component "$APEX_KERNEL_SRC" .github/scripts/libfprint.sh build /build/libfprint || rc=$?
    COMPONENT_ENV=()
    case $rc in
        0) sign_rpms "$BUILD/libfprint" ;;
        3) echo "libfprint: patches do not apply; the image uses Fedora's libfprint (degraded=fingerprint)"
           libfprint_args=() ;;
        *) echo "libfprint: build failed (exit $rc)" >&2; exit "$rc" ;;
    esac

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
        grep -nE 'JS ERROR|CRITICAL|crashed with signal|Segmentation fault|== Stack trace|^#[0-9]+ ' \
            "$G2_FIRST_RUN/$case.log" | head -n 40 | cut -c1-"$G2_EXCERPT_WIDTH"
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
    local image_only=$1 rc=0 last_pass
    echo "== G4, when qualify.sh g4-due says it is due"
    qualify g4-key "$IMAGE" >"$G4_KEY" || return
    last_pass=$(qualify g4-due "$G4_KEY") || rc=$?
    case $rc in
        0)
            if ((image_only)); then
                G4_VERDICT=due
                echo "G4 is due but not run with --image-only: just vm-qualify, then just vm-image-only, before just pkg-promote"
            elif run_g4; then
                G4_VERDICT="passed for image $(image_id)"
            else
                echo "G4 failed (_build/qualify/results.md): $IMAGE is built, but its lock must not be promoted" >&2
                return 1
            fi ;;
        "$G4_NOT_DUE")
            G4_VERDICT="not due: its key passed on $(sed -n 's/^passed-at //p' <<<"$last_pass") for image $(sed -n 's/^image-id //p' <<<"$last_pass")" ;;
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
    printf 'lock-sha256 %s\nimage-id %s\ng2 passed\ng4 %s\ncomponents %s\n' "$image_lock" "$id" "$G4_VERDICT" \
        "${APEX_COMPONENTS:-unknown}" >"$GATES_PASSED"
    echo "G1 and G2 passed for $IMAGE (image $id); G4 $G4_VERDICT"
    echo "just pkg-promote makes the lane lock it carries rpms.lock"
}

main() {
    local image_only=0
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
    rm -f "$GATES_PASSED"
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
    gate_g2 || exit
    gate_g4 "$image_only" || exit
    [[ $G4_VERDICT == due ]] || record_gates || exit
    echo "build-image: done; state in ~/apex-image/_build/image"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
