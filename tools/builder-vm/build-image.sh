#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest-side image build for `builder-vm.sh image` (`just vm-image`), run in
# ~/apex-fedora inside the builder VM (see `just image`). Nothing is pushed or signed.
#
#   1. the apex RPM          .github/scripts/rpms.sh build       (in fedora:45, as root)
#   2. the patched libfprint .github/scripts/libfprint.sh build  (exit 3 = degraded)
#   3. the image             .github/scripts/image.sh context, build, inspect
#
# With --image-only, steps 1 and 2 are skipped and the RPMs of the previous run in
# _build/rpms and _build/libfprint are reused (for Containerfile or image/ changes).
set -euo pipefail

image_only=0
case ${1:-} in
    --image-only) image_only=1 ;;
    '') ;;
    *) echo "usage: build-image.sh [--image-only]" >&2; exit 2 ;;
esac

cd "$HOME/apex-fedora"
readonly FEDORA=registry.fedoraproject.org/fedora:45
# Every full run starts from empty outputs: the containers write them as root, and a
# stale RPM next to a new one would let dnf pick either.
if ((!image_only)); then
    sudo rm -rf _build/rpms _build/libfprint
elif [[ ! -s _build/rpms/SHA256SUMS ]]; then
    echo "--image-only needs the RPMs of an earlier full run in _build/rpms" >&2
    exit 1
fi
mkdir -p _build

in_fedora() { sudo podman run --rm --pull=newer -v "$PWD:/src:z" -w /src "$FEDORA" "$@"; }

# rpms.sh and image.sh build from git HEAD. This checkout is an rsync copy
# whose .git directory is independent of the host repository, so uncommitted host
# changes are captured here in a throwaway snapshot commit. It never leaves the VM:
# the next sync replaces this .git with the host's.
if ! git rev-parse -q --verify HEAD >/dev/null || [[ -n $(git status --porcelain) ]]; then
    git add -A
    git -c user.name='Apex builder VM' -c user.email='builder-vm@localhost' \
        commit -q --no-verify -m 'builder-vm snapshot of the host working tree (local only, never pushed)'
    echo "snapshot commit $(git rev-parse --short=12 HEAD) of the host working tree (VM copy only)"
fi

libfprint_args=(--libfprint-dir _build/libfprint)
if ((image_only)); then
    echo "== 1/3, 2/3 skipped (--image-only): reusing _build/rpms and _build/libfprint"
    [[ -d _build/libfprint && -n $(ls -A _build/libfprint) ]] || libfprint_args=()
else
    echo "== 1/3 apex RPM"
    in_fedora .github/scripts/rpms.sh build /src/_build/rpms

    echo "== 2/3 libfprint"
    rc=0
    in_fedora .github/scripts/libfprint.sh build /src/_build/libfprint || rc=$?
    case $rc in
        0) ;;
        3) echo "libfprint: patches do not apply; the image uses Fedora's libfprint (degraded=fingerprint)"
           libfprint_args=() ;;
        *) echo "libfprint: build failed (exit $rc)" >&2; exit "$rc" ;;
    esac
fi

echo "== 3/3 image"
.github/scripts/image.sh context --rpms-dir _build/rpms "${libfprint_args[@]}"
.github/scripts/image.sh build
.github/scripts/image.sh inspect
echo "build-image: done; state in ~/apex-fedora/_build/image"
