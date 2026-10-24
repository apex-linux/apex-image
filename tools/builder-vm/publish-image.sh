#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: publish-image.sh [--allow-degraded] [--rehearse]

Guest-side `just publish` (roadmap S1d), run in ~/apex-image inside the builder VM after
`just vm-image`. It publishes the last built image only when _build/gates-passed.txt
names it and its components were pinned: image.sh rechunk against apex:45, then
publish.sh publish, which pushes apex:<version>, signs it with the owner's cosign key and
moves apex:45 to it after the committed policy verifies the signature. The image must
carry the checkout's release.pub, so a build from before the owner's key never publishes.

--allow-degraded is the owner's override for a candidate degraded in a component apex:45
is not. --rehearse runs the same steps against a throwaway registry and key on this host
(publish.sh rehearse); it needs no gates record and publishes nothing.
EOF
}

readonly GATES_PASSED=_build/gates-passed.txt
readonly IMAGE=localhost/apex:build
readonly RELEASE_KEY=/usr/share/apex/keys/release.pub

image_id() { sudo podman image inspect --format '{{.Id}}' "$IMAGE"; }

# rpm-ostree writes the layout as root; publish.sh reads it as this user.
rechunk() {
    APEX_PREVIOUS_BUILD=$1 .github/scripts/image.sh rechunk
    sudo chown -R "$(id -u):$(id -g)" -- _build/image/oci
}

gated() {
    local id
    [[ -s $GATES_PASSED ]] || { echo "no $GATES_PASSED: just vm-image has not passed G2 and G4 for $IMAGE" >&2; return 1; }
    id=$(image_id) || { echo "no $IMAGE (just vm-image)" >&2; return 1; }
    [[ $(sed -n 's/^image-id //p' "$GATES_PASSED") == "$id" ]] ||
        { echo "$GATES_PASSED names another image than $IMAGE ($id): just vm-image again" >&2; return 1; }
    grep -qx 'components pinned' "$GATES_PASSED" ||
        { echo "$IMAGE was built from a dev-override component; only pinned components publish" >&2; return 1; }
}

carries_release_key() {
    local in_image
    in_image=$(sudo podman run --rm --net=none --entrypoint /usr/bin/sha256sum "$IMAGE" "$RELEASE_KEY") ||
        { echo "$IMAGE has no $RELEASE_KEY" >&2; return 1; }
    [[ ${in_image%% *} == "$(sha256sum <"image/system_files$RELEASE_KEY" | cut -d' ' -f1)" ]] ||
        { echo "$IMAGE carries another $RELEASE_KEY than this checkout: build it again (just vm-image)" >&2; return 1; }
}

main() {
    local rehearse=0
    local -a flags=()
    while (($#)); do
        case $1 in
            --allow-degraded) flags+=(--allow-degraded); shift ;;
            --rehearse) rehearse=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    cd "$HOME/apex-image"
    if ((rehearse)); then
        ((${#flags[@]} == 0)) || { echo "--rehearse publishes nothing to override" >&2; exit 2; }
        rechunk none
        .github/scripts/publish.sh rehearse "oci:$PWD/_build/image/oci/apex:latest"
        return
    fi
    gated
    carries_release_key
    # shellcheck disable=SC2016 # expanded by the child shell that sourced lib.sh
    rechunk "$(bash -c '. .github/scripts/lib.sh && printf "%s:%s" "$APEX_REPO_STABLE" "$APEX_FEDORA"')"
    .github/scripts/publish.sh publish "${flags[@]}" "oci:$PWD/_build/image/oci/apex:latest"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
