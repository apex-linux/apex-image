#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest-side image build for `builder-vm.sh image`, run in ~/apex-fedora inside the
# builder VM. Nothing is pushed or signed, and nothing promotes the lane's lock.
#
#   build-image.sh [--image-only]
#
# --image-only reuses the RPMs and the lane lock of the previous run (for Containerfile
# or image/ changes).
set -euo pipefail

image_only=0
case ${1:-} in
    --image-only) image_only=1 ;;
    '') ;;
    *) echo "usage: build-image.sh [--image-only]" >&2; exit 2 ;;
esac

cd "$HOME/apex-fedora"
readonly FEDORA=registry.fedoraproject.org/fedora:45
readonly LANE_LOCK=${APEX_STORE:-$HOME/apex-store}/rpms.lock.next
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
mkdir -p _build

in_fedora() { sudo podman run --rm --pull=newer -v "$PWD:/src:z" -w /src "$FEDORA" "$@"; }

# rpms.sh, apex-lane and image.sh build from git HEAD: uncommitted host changes become a
# throwaway snapshot commit in this VM copy of the checkout (snapshot.sh).
tools/builder-vm/snapshot.sh

libfprint_args=(--libfprint-dir _build/libfprint)
if ((image_only)); then
    echo "== 1/4 to 3/4 skipped (--image-only): reusing _build/rpms, _build/libfprint and $LANE_LOCK"
    [[ -d _build/libfprint && -n $(ls -A _build/libfprint) ]] || libfprint_args=()
else
    echo "== 1/4 apex and apex-desktop RPMs"
    in_fedora .github/scripts/rpms.sh build /src/_build/rpms

    echo "== 2/4 libfprint"
    rc=0
    in_fedora .github/scripts/libfprint.sh build /src/_build/libfprint || rc=$?
    case $rc in
        0) ;;
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
fi

echo "== 4/4 image"
.github/scripts/image.sh context --rpms-dir _build/rpms "${libfprint_args[@]}" --lane-lock "$LANE_LOCK"
.github/scripts/image.sh build
.github/scripts/image.sh inspect
tools/builder-vm/lane.sh status
echo "build-image: done; state in ~/apex-fedora/_build/image"
echo "After the image passed its gates (G2, and G4 for a new gnome-shell, mutter or gdm NVR): just pkg-promote"
