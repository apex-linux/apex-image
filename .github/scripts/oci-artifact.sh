#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Content-addressed RPM artifacts on ghcr.io (ADR 0013): a FROM scratch image whose
# only layer holds /rpms/*.rpm and /rpms/SHA256SUMS.
#
#   oci-artifact.sh digest REF          print the digest of REF; exit 3 when it is absent,
#                                       4 when access is denied (a cache miss to callers)
#   oci-artifact.sh lookup REPO KEY WORKFLOW
#                                       the cache lookup: print the digest of REPO:KEY only
#                                       when WORKFLOW (rpms.yml, libfprint.yml) on main
#                                       attested it and it carries content-key=KEY; exit 3
#                                       absent, 4 access denied, 5 not attested (all three
#                                       are cache misses: rebuild and publish again)
#   oci-artifact.sh push DIR REPO TAG   push DIR/*.rpm as REPO:TAG, print REPO@DIGEST
#   oci-artifact.sh pull REF DEST       copy the RPMs of REF into DEST and verify them
#
# push uses buildah (rootful through sudo when not root); pull, digest and lookup use
# skopeo; lookup also uses gh (GH_TOKEN, with attestations: read). REGISTRY_AUTH_FILE,
# when set, is used for every registry call.
#
# Why lookup checks provenance: the tags are mutable and anyone holding a packages:
# write token for the repository could point apex-rpms:<key> at other RPMs, which the
# image build would install and the CI key would then sign. Every publish job attests
# the digest it pushed (actions/attest-build-provenance), and a cached artifact is
# reused only when that attestation verifies for this repository, the given workflow
# at refs/heads/main, a GitHub-hosted runner, and the key in the artifact's own label.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd_digest() {
    (($# == 1)) || die "usage: oci-artifact.sh digest REF"
    require skopeo jq
    registry_digest "$1"
}

# verify_provenance REPO DIGEST WORKFLOW: gh attestation verify for REPO@DIGEST. The
# raw manifest is the subject: its SHA-256 is DIGEST (checked here as well), and gh
# looks attestations up by that digest.
verify_provenance() {
    local repo=$1 digest=$2 workflow=$3 tmp rc=0 identity
    require gh sha256sum
    tmp=$(mktemp -d)
    registry_manifest "$repo@$digest" "$tmp/manifest.json" || rc=$?
    if ((rc != 0)) || [[ sha256:$(sha256sum <"$tmp/manifest.json" | cut -d' ' -f1) != "$digest" ]]; then
        rm -rf "$tmp"
        log "cannot fetch the manifest of $repo@$digest (exit $rc)"
        return 1
    fi
    identity="https://github.com/$APEX_GITHUB_REPO/.github/workflows/$workflow@refs/heads/main"
    gh attestation verify "$tmp/manifest.json" --repo "$APEX_GITHUB_REPO" \
        --cert-identity "$identity" --source-ref refs/heads/main \
        --deny-self-hosted-runners >&2 || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

cmd_lookup() {
    (($# == 3)) || die "usage: oci-artifact.sh lookup REPO KEY WORKFLOW"
    local repo=$1 key=$2 workflow=$3 digest rc=0 label
    [[ $workflow =~ ^[a-z0-9-]+\.yml$ ]] || die "invalid workflow file name '$workflow'"
    require skopeo jq
    digest=$(registry_digest "$repo:$key") || rc=$?
    ((rc == 0)) || return "$rc"
    if ! verify_provenance "$repo" "$digest" "$workflow"; then
        warn "$repo:$key ($digest) has no valid attestation by $workflow on main; treating it as a cache miss"
        return 5
    fi
    rc=0
    label=$(registry_label "$repo@$digest" "$APEX_LABEL_PREFIX.content-key") || rc=$?
    ((rc == 0)) || return 1
    if [[ $label != "$key" ]]; then
        warn "$repo:$key ($digest) is labelled content-key '$label'; treating it as a cache miss"
        return 5
    fi
    printf '%s\n' "$digest"
}

cmd_push() {
    (($# == 3)) || die "usage: oci-artifact.sh push DIR REPO TAG"
    local dir=$1 repo=$2 tag=$3
    require buildah sha256sum
    compgen -G "$dir/*.rpm" >/dev/null || die "no RPMs in $dir"
    [[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid tag '$tag'"
    (cd "$dir" && sha256sum --check --strict --quiet SHA256SUMS) ||
        die "$dir/SHA256SUMS does not match the RPMs"

    local -a auth=()
    [[ -z ${REGISTRY_AUTH_FILE:-} ]] || auth=(--authfile "$REGISTRY_AUTH_FILE")
    local ctr digestfile
    digestfile=$(mktemp)
    ctr=$(as_root buildah from scratch)
    # shellcheck disable=SC2064 # expand now: the trap must remove this container.
    trap "as_root buildah rm '$ctr' >/dev/null 2>&1 || true; rm -f '$digestfile'" EXIT
    as_root buildah copy --chmod 0644 "$ctr" "$dir"/*.rpm "$dir/SHA256SUMS" /rpms/ >/dev/null
    as_root buildah config \
        --label "org.opencontainers.image.source=$APEX_SOURCE_URL" \
        --label "org.opencontainers.image.revision=${GITHUB_SHA:-$(git -C "$APEX_ROOT" rev-parse HEAD)}" \
        --label "$APEX_LABEL_PREFIX.content-key=$tag" \
        --label "org.opencontainers.image.description=Apex build artifact (RPMs), not a runnable image" \
        "$ctr"
    # --timestamp 0 keeps the artifact free of build-time metadata.
    as_root buildah commit --quiet --timestamp 0 "$ctr" "localhost/apex-artifact:$tag" >/dev/null
    retry 4 10 as_root buildah push "${auth[@]}" --digestfile "$digestfile" \
        "localhost/apex-artifact:$tag" "docker://$repo:$tag"
    local digest
    digest=$(as_root cat "$digestfile")
    is_digest "$digest" || die "buildah push reported no digest"
    as_root buildah rmi "localhost/apex-artifact:$tag" >/dev/null || true
    log "pushed $repo:$tag as $digest"
    printf '%s@%s\n' "$repo" "$digest"
}

cmd_pull() {
    (($# == 2)) || die "usage: oci-artifact.sh pull REF DEST"
    local ref=$1 dest=$2
    require skopeo jq tar sha256sum
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064 # expand now: $tmp is local and gone when EXIT fires.
    trap "rm -rf '$tmp'" EXIT
    local -a auth
    mapfile -t auth < <(skopeo_auth_args)
    # A digest reference makes skopeo verify the manifest; layers are verified by digest.
    retry 4 10 skopeo copy --quiet "${auth[@]}" "docker://$ref" "dir:$tmp/img"
    mkdir -p "$tmp/root" "$dest"
    local layer
    while IFS= read -r layer; do
        tar -xf "$tmp/img/${layer#sha256:}" -C "$tmp/root" --no-same-owner
    done < <(jq -r '.layers[].digest' "$tmp/img/manifest.json")
    [[ -f $tmp/root/rpms/SHA256SUMS ]] || die "$ref has no /rpms/SHA256SUMS"
    (cd "$tmp/root/rpms" && sha256sum --check --strict --quiet SHA256SUMS) ||
        die "$ref: RPM checksums do not match SHA256SUMS"
    cp -- "$tmp"/root/rpms/*.rpm "$dest/"
    log "extracted $(find "$tmp/root/rpms" -name '*.rpm' | wc -l) RPM(s) from $ref into $dest"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        digest) cmd_digest "$@" ;;
        lookup) cmd_lookup "$@" ;;
        push) cmd_push "$@" ;;
        pull) cmd_pull "$@" ;;
        *) usage ;;
    esac
}

# selftest.sh sources this file to test its functions; only a direct run starts main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
