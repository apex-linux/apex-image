#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: build-image.sh [--image-only]

Guest-side image build for `builder-vm.sh image`, run in ~/apex-fedora inside the
builder VM. The Apex RPM key signs every RPM; nothing is pushed, the image is not
signed, and nothing promotes the lane's lock. G1 runs in the build, G2
(tests/shots/run.sh, twice) after it, and G4 (qualify.sh local) when qualify.sh g4-due
says it is due: the image's G4 key differs from the last pass, or that pass is a week
old. When G2 passed and G4 passed or was not due, _build/gates-passed.txt names the lane
lock the image carries, the image, and G4's verdict; `lane.sh promote` requires it. The
record is not written when the lane lock moved while the gates ran.

With a components.lock, tools/components.sh fetch and env run before the first build
step, and libfprint is built from the packaging/libfprint of APEX_KERNEL_SRC.

--image-only reuses the RPMs and the lane lock of the previous run (for Containerfile
or image/ changes), and only says whether G4 is due.
EOF
}

readonly FEDORA=registry.fedoraproject.org/fedora:45
readonly LANE_LOCK=${APEX_STORE:-$HOME/apex-store}/rpms.lock.next
readonly GATES_PASSED=_build/gates-passed.txt
readonly G2_RESULT=_build/g2/latest/result.txt
readonly G4_KEY=_build/image/g4-key.txt
readonly IMAGE=localhost/apex:build
readonly G2_RUNS_PER_BUILD=2
readonly G4_NOT_DUE=3

G4_VERDICT=

in_fedora() { sudo podman run --rm --pull=newer -v "$PWD:/src:z" "${FEDORA_MOUNTS[@]}" -w /src "$FEDORA" "$@"; }
FEDORA_MOUNTS=()

# libfprint.sh runs the build.sh and series of the component that holds packaging/libfprint.
libfprint_mounts() {
    local src=${APEX_KERNEL_SRC:-$PWD}
    [[ ! $src -ef $PWD ]] || return 0
    [[ -d $src/packaging/libfprint ]] || { echo "APEX_KERNEL_SRC=$src has no packaging/libfprint" >&2; return 1; }
    printf '%s\n' -v "$src/packaging/libfprint:/src/packaging/libfprint:ro,z"
}

use_components() {
    [[ -f components.lock ]] || return 0
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
run_g2() { G2_RUNS=$G2_RUNS_PER_BUILD tests/shots/run.sh "$IMAGE"; }
run_g4() { QUALIFY_MEM=3G QUALIFY_SMP=4 qualify local "$IMAGE"; }

build_inputs() {
    echo "== 1/4 apex and apex-desktop RPMs"
    in_fedora .github/scripts/rpms.sh build /src/_build/rpms
    sign_rpms _build/rpms

    echo "== 2/4 libfprint"
    local rc=0 mounts
    mounts=$(libfprint_mounts)
    mapfile -t FEDORA_MOUNTS <<<"$mounts"
    [[ -n $mounts ]] || FEDORA_MOUNTS=()
    in_fedora .github/scripts/libfprint.sh build /src/_build/libfprint || rc=$?
    FEDORA_MOUNTS=()
    case $rc in
        0) sign_rpms _build/libfprint ;;
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
    .github/scripts/image.sh context --rpms-dir _build/rpms "${libfprint_args[@]}" --lane-lock "$LANE_LOCK"
    .github/scripts/image.sh build
    .github/scripts/image.sh inspect
    tools/builder-vm/lane.sh status
}

gate_g2() {
    echo "== G2, the headless shell, $G2_RUNS_PER_BUILD runs"
    if ! run_g2; then
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
    id=$(image_id) || return
    image_lock=$(sed -n 's/^lock-sha256 //p' "$G2_RESULT")
    lane_lock=$(sha256_of "$LANE_LOCK") || return
    if [[ -z $image_lock || $image_lock != "$lane_lock" ]]; then
        echo "the lane lock moved while the gates ran: $IMAGE carries ${image_lock:-no lock}, $LANE_LOCK is now $lane_lock; nothing is recorded (just vm-image again)" >&2
        return 1
    fi
    printf 'lock-sha256 %s\nimage-id %s\ng2 passed\ng4 %s\n' "$image_lock" "$id" "$G4_VERDICT" >"$GATES_PASSED"
    echo "G1 and G2 passed for $IMAGE (image $id); G4 $G4_VERDICT"
    echo "just pkg-promote makes the lane lock it carries rpms.lock"
}

main() {
    local image_only=0
    case ${1:-} in
        --image-only) image_only=1 ;;
        -h | --help) usage; exit 0 ;;
        '') ;;
        *) usage >&2; exit 2 ;;
    esac

    cd "$HOME/apex-fedora"
    rm -f "$GATES_PASSED"
    # Every full run starts from empty outputs: the containers write them as root, and a
    # stale RPM next to a new one would let dnf pick either.
    if ((!image_only)); then
        sudo rm -rf _build/rpms _build/libfprint
    elif [[ ! -s _build/rpms/SHA256SUMS ]]; then
        echo "--image-only needs the RPMs of an earlier full run in _build/rpms" >&2
        exit 1
    elif [[ ! -s $LANE_LOCK ]]; then
        echo "--image-only needs the lane's $LANE_LOCK of an earlier full run (or just pkg-build)" >&2
        exit 1
    fi
    mkdir -p _build/image

    # rpms.sh, apex-lane and image.sh build from git HEAD, not from the working tree.
    tools/builder-vm/snapshot.sh
    use_components

    libfprint_args=(--libfprint-dir _build/libfprint)
    if ((image_only)); then
        echo "== 1/4 to 3/4 skipped (--image-only): reusing _build/rpms, _build/libfprint and $LANE_LOCK"
        [[ -d _build/libfprint && -n $(ls -A _build/libfprint) ]] || libfprint_args=()
    else
        build_inputs
    fi
    build_image

    gate_g2 || exit
    gate_g4 "$image_only" || exit
    [[ $G4_VERDICT == due ]] || record_gates || exit
    echo "build-image: done; state in ~/apex-fedora/_build/image"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
