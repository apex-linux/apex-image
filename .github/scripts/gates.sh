#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: gates.sh build OUT

The hosted gates (.github/workflows/gates.yml): G1, G2 and G4 on GitHub's runners, before
a merge, with no owner hardware.

  gates.sh build OUT   on the runner: start a privileged fedora:45 (the REPOS_BASE pin) on
                       GATES_WORK (the runner's second disk), and in it build-in OUT
  gates.sh build-in OUT
                       in that container: the components' RPMs, the lane and the image, as
                       build-image.sh builds them, G1 in the image build; then OUT/apex.oci.zst
                       (podman save, zstd) and OUT/build.txt

Every RPM is signed by an ephemeral key made in the job. Its secret half stays in
GATES_WORK/gnupg and is never uploaded or cached. Its public half replaces the committed
RPM-GPG-KEY-apex in this job's checkout only, which apex-lane requires. The image carries
/usr/share/apex/test-key and the label <prefix>.rpm-key=test:FPR: G1 checks the image
against that key, and publish.sh, image.sh push, cosign and lane.sh promote refuse it.

build.txt: sha, image-id, content-key, rpm-key, lock-sha256, seconds.
EOF
    exit 2
}

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
readonly ROOT
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/.github/scripts/lib.sh"
readonly KEY_FILE=image/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex
readonly BUILD_TOOLS=(podman skopeo buildah git-core gnupg2 rpm-sign jq zstd python3 sudo findutils diffutils
    gawk tar gzip xz cpio openssl util-linux procps-ng which rsync file)

cmd_build() {
    (($# == 1)) || usage
    local out=$1 work=${GATES_WORK:?GATES_WORK names the work directory, on the second disk} fedora
    fedora=$(containerfile_arg REPOS_BASE)
    is_fedora_pin "$fedora" || die "image/Containerfile REPOS_BASE '$fedora' is not a digest pin"
    mkdir -p "$out" "$work"
    # Its own podman runs nested: its store and every container's under GATES_WORK.
    sudo podman run --rm --privileged --security-opt label=disable --network host \
        -v "$ROOT:/src:z" -v "$work:/work:z" -v "$out:/out:z" -w /src \
        -e GITHUB_ACTIONS -e GITHUB_STEP_SUMMARY=/out/summary.md -e GITHUB_RUN_NUMBER -e GITHUB_SHA \
        -e GATES_SHA="${GATES_SHA:-$(git -C "$ROOT" rev-parse HEAD)}" \
        "$fedora" /src/.github/scripts/gates.sh build-in /out
}

# The secret half never leaves GNUPGHOME; the checkout's public key is the job's own.
ephemeral_key() {
    local home=$1 fpr
    install -d -m 0700 "$home"
    gpg --homedir "$home" --batch --quiet --passphrase '' \
        --quick-gen-key "Apex gates test key (ephemeral, $(date -u +%FT%TZ))" ed25519 sign 1d
    fpr=$(gpg --homedir "$home" --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
    [[ $fpr =~ ^[0-9A-F]{40}$ ]] || die "the ephemeral key has no fingerprint"
    gpg --homedir "$home" --batch --armor --export "$fpr" >"$ROOT/$KEY_FILE"
    printf 'APEX_RPM_KEY_FPR=%s\nAPEX_RPM_GNUPGHOME=%s\n' "$fpr" "$home" >"$home.env"
    printf '%s\n' "$fpr"
}

cmd_build_in() {
    (($# == 1)) || usage
    local out=$1 t0=$SECONDS fpr
    [[ -d /work ]] || die "build-in runs in gates.sh build's container"
    retry 3 10 dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${BUILD_TOOLS[@]}"
    mkdir -p /work/containers /work/home
    printf '[storage]\ndriver = "overlay"\ngraphroot = "/work/containers"\nrunroot = "/run/containers/storage"\n' \
        >/etc/containers/storage.conf
    git config --global --add safe.directory /src
    export HOME=/work/home APEX_STORE=/work/apex-store APEX_RPM_CACHE=/work/rpm-cache XDG_CACHE_HOME=/work/cache
    fpr=$(ephemeral_key /work/gnupg)
    export APEX_RPM_SIGNING_ENV=/work/gnupg.env APEX_TEST_KEY=$fpr
    log "gates: RPMs signed by the ephemeral key $fpr (secret in /work/gnupg, never uploaded)"

    cd "$ROOT"
    # shellcheck source=SCRIPTDIR/../../tools/builder-vm/build-image.sh
    . tools/builder-vm/build-image.sh
    sudo rm -rf "$BUILD/rpms" "$BUILD/libfprint"
    mkdir -p _build/image
    use_components
    libfprint_args=(--libfprint-dir "$BUILD/libfprint")
    build_inputs
    build_image

    local id key lock
    id=$(image_id)
    key=$(sed -n 's/^CONTENT_KEY=//p' "${APEX_WORK:-_build/image}/image.env" 2>/dev/null | tail -n 1)
    lock=$(sha256_of "$LANE_LOCK")
    sudo podman save --format oci-archive "$IMAGE" | zstd -T0 -3 -q -o "$out/apex.oci.zst"
    printf 'sha %s\nimage-id %s\ncontent-key %s\nrpm-key test:%s\nlock-sha256 %s\nseconds %s\n' \
        "${GATES_SHA:-$(git rev-parse HEAD)}" "$id" "${key:-unknown}" "$fpr" "$lock" "$((SECONDS - t0))" >"$out/build.txt"
    cat "$out/build.txt"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        build) cmd_build "$@" ;;
        build-in) cmd_build_in "$@" ;;
        *) usage ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
