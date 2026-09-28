#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sign, tag and promote Apex images. Only digests move; nothing is rebuilt.
#
#   publish.sh sign REPO DIGEST             cosign-sign REPO@DIGEST (legacy .sig format)
#   publish.sh tag-testing DIGEST VERSION   move apex-testing:45 to DIGEST
#   publish.sh promote-copy DIGEST          copy apex-testing@DIGEST to apex:<version>
#   publish.sh promote-tag DIGEST           move apex:45 to DIGEST
#   publish.sh version DIGEST               print the candidate's version label
#
# A tag moves only to a digest that passes the image's own committed policy, with a newer
# version built from the same or a later commit of main (needs fetch-depth: 0).
#
# Environment: REGISTRY_AUTH_FILE (write access for tag moves); for sign also
# COSIGN_PRIVATE_KEY, COSIGN_PASSWORD, GH_TOKEN and GITHUB_ACTOR, and cosign on PATH.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly SYSTEM_FILES="$APEX_ROOT/image/system_files"
readonly COMMITTED_POLICY="$SYSTEM_FILES/usr/share/apex/containers/policy.json"
readonly TAG_ALREADY_THERE=10

checkout_policy() {
    [[ -f $COMMITTED_POLICY ]] || die "missing $COMMITTED_POLICY: cannot verify signatures"
    local out
    out=$(mktemp --suffix=.json)
    policy_key_root "$SYSTEM_FILES" <"$COMMITTED_POLICY" >"$out"
    # A policy that accepts anything would make every verified copy prove nothing.
    policy_rejects_by_default <"$out" || die "$COMMITTED_POLICY does not default to reject"
    printf '%s\n' "$out"
}

require_keys() {
    local k f
    for k in "$@"; do
        f="$SYSTEM_FILES/usr/share/apex/keys/$k.pub"
        [[ -f $f ]] || die "missing $f"
        if grep -qx 'APEX-PLACEHOLDER-NOT-A-KEY' "$f"; then
            die "$f is still the placeholder; generate the key and commit its public half (see image/system_files/usr/share/apex/keys/README.md)"
        fi
    done
}

checkout_registries_d() {
    local dir committed
    dir=$(mktemp -d)
    committed=$(grep -rl --include='*.yaml' --include='*.yml' 'use-sigstore-attachments' \
        "$SYSTEM_FILES" 2>/dev/null | head -n 1 || true)
    if [[ -n $committed ]]; then
        cp -- "$committed" "$dir/"
    else
        warn "no registries.d file with use-sigstore-attachments under image/system_files; using a generated one"
        printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$APEX_NAMESPACE" >"$dir/apex.yaml"
    fi
    printf '%s\n' "$dir"
}

verified_copy() {
    local src=$1 dst=$2 policy regd
    policy=$(checkout_policy)
    regd=$(checkout_registries_d)
    local -a auth
    mapfile -t auth < <(skopeo_auth_args)
    log "copy (policy-verified) $src -> $dst"
    retry 3 15 skopeo --policy "$policy" --registries.d "$regd" copy --quiet \
        --preserve-digests --remove-signatures "${auth[@]}" "docker://$src" "docker://$dst"
    rm -rf "$policy" "$regd"
}

# candidate_labels DIGEST: prints "VERSION REVISION" of apex-testing@DIGEST.
candidate_labels() {
    local digest=$1 json version fedora revision
    is_digest "$digest" || die "invalid digest '$digest'"
    json=$(registry_inspect "$APEX_REPO_TESTING@$digest") || die "cannot inspect $APEX_REPO_TESTING@$digest"
    version=$(jq -r '.Labels["org.opencontainers.image.version"] // ""' <<<"$json")
    fedora=$(jq -r --arg l "$APEX_LABEL_PREFIX.fedora" '.Labels[$l] // ""' <<<"$json")
    revision=$(jq -r '.Labels["org.opencontainers.image.revision"] // ""' <<<"$json")
    version_valid "$version" || die "candidate has no valid version label (got '$version')"
    [[ $fedora == "$APEX_FEDORA" && $version == "$APEX_FEDORA".* ]] ||
        die "candidate is Fedora '$fedora' version '$version', not Fedora $APEX_FEDORA"
    [[ $revision =~ ^[0-9a-f]{40}$ ]] || die "candidate has no valid revision label (got '$revision')"
    printf '%s %s\n' "$version" "$revision"
}

candidate_version() {
    local labels
    labels=$(candidate_labels "$1")
    printf '%s\n' "${labels% *}"
}

# The version's date is the build date, so a re-run of an old run would carry old code
# under a newer version: the commit must descend from the current tag's as well.
check_increases() {
    local ref=$1 digest=$2 version=$3 revision=$4 json rc=0 cur_digest cur_version cur_revision
    json=$(registry_inspect "$ref") || rc=$?
    case $rc in
        0) ;;
        "$REGISTRY_ABSENT")
            registry_tag_absent "${ref%:*}" "${ref##*:}" ||
                die "inspect found no $ref but list-tags does not confirm it; refusing to treat it as a first publication"
            log "$ref does not exist yet; first publication"
            return 0
            ;;
        *) die "cannot read $ref; refusing to move it without knowing its current version" ;;
    esac
    cur_digest=$(jq -r '.Digest' <<<"$json")
    cur_version=$(jq -r '.Labels["org.opencontainers.image.version"] // ""' <<<"$json")
    cur_revision=$(jq -r '.Labels["org.opencontainers.image.revision"] // ""' <<<"$json")
    if [[ $cur_digest == "$digest" ]]; then
        log "$ref already points at $digest"
        return "$TAG_ALREADY_THERE"
    fi
    version_valid "$cur_version" || die "$ref carries no valid version label ('$cur_version')"
    version_gt "$version" "$cur_version" ||
        die "refusing to move $ref from $cur_version to $version: versions must increase (ADR 0012)"
    rc=0
    revision_descends "$cur_revision" "$revision" || rc=$?
    case $rc in
        0) ;;
        1) die "refusing to move $ref from commit $cur_revision ($cur_version) to $revision ($version):" \
            "the candidate's commit does not descend from the current one (a re-run of an older run?)" ;;
        *) die "cannot order commits $cur_revision ($ref) and $revision (candidate): not both in" \
            "this checkout's history (fetch-depth: 0?); refusing to move $ref" ;;
    esac
    log "$ref: $cur_version -> $version (commit ${cur_revision:0:12} -> ${revision:0:12})"
}

cmd_sign() {
    (($# == 2)) || die "usage: publish.sh sign REPO DIGEST"
    local repo=$1 digest=$2
    is_digest "$digest" || die "invalid digest '$digest'"
    [[ $repo == "$APEX_REPO_TESTING" || $repo == "$APEX_REPO_STABLE" ]] || die "unexpected repository $repo"
    [[ -n ${COSIGN_PRIVATE_KEY:-} ]] || die "COSIGN_PRIVATE_KEY is not set (environment secret)"
    [[ -n ${GH_TOKEN:-} ]] || die "GH_TOKEN is not set"
    require cosign
    DOCKER_CONFIG=$(mktemp -d)
    export DOCKER_CONFIG
    printf '%s' "$GH_TOKEN" | cosign login "$APEX_REGISTRY" \
        --username "${GITHUB_ACTOR:-apex-ci}" --password-stdin >/dev/null
    # Legacy .sig tags: containers/image (bootc, skopeo, podman) cannot verify the new
    # bundle format yet. Rekor upload stays on for leak detection.
    retry 3 15 cosign sign --yes --new-bundle-format=false --use-signing-config=false \
        --key env://COSIGN_PRIVATE_KEY "$repo@$digest"
    rm -rf "$DOCKER_CONFIG"
    summary "Signed \`$repo@$digest\`."
}

cmd_tag_testing() {
    (($# == 2)) || die "usage: publish.sh tag-testing DIGEST VERSION"
    local digest=$1 version=$2 labels labelled revision rc=0
    require_keys ci
    labels=$(candidate_labels "$digest")
    labelled=${labels% *} revision=${labels#* }
    [[ $labelled == "$version" ]] || die "candidate is labelled $labelled, the build said $version"
    check_increases "$APEX_REPO_TESTING:$APEX_FEDORA" "$digest" "$version" "$revision" || rc=$?
    case $rc in
        0) verified_copy "$APEX_REPO_TESTING@$digest" "$APEX_REPO_TESTING:$APEX_FEDORA" ;;
        "$TAG_ALREADY_THERE") ;;
        *) return "$rc" ;;
    esac
    summary "\`$APEX_REPO_TESTING:$APEX_FEDORA\` -> \`$digest\` ($version)"
}

cmd_promote_copy() {
    (($# == 1)) || die "usage: publish.sh promote-copy DIGEST"
    local digest=$1 labels version revision rc=0 existing
    require_keys ci release release-backup
    labels=$(candidate_labels "$digest")
    version=${labels% *} revision=${labels#* }
    check_increases "$APEX_REPO_STABLE:$APEX_FEDORA" "$digest" "$version" "$revision" || rc=$?
    ((rc == 0 || rc == TAG_ALREADY_THERE)) || return "$rc"
    rc=0
    existing=$(registry_digest "$APEX_REPO_STABLE:$version") || rc=$?
    case $rc in
        0)
            [[ $existing == "$digest" ]] ||
                die "$APEX_REPO_STABLE:$version already exists as $existing; version tags are immutable"
            log "$APEX_REPO_STABLE:$version already points at $digest"
            ;;
        "$REGISTRY_ABSENT")
            registry_tag_absent "$APEX_REPO_STABLE" "$version" ||
                die "inspect found no $APEX_REPO_STABLE:$version but list-tags does not confirm it; not overwriting a version tag"
            verified_copy "$APEX_REPO_TESTING@$digest" "$APEX_REPO_STABLE:$version"
            ;;
        *) die "cannot read $APEX_REPO_STABLE:$version" ;;
    esac
    set_output version "$version"
    summary "Copied \`$APEX_REPO_TESTING@$digest\` to \`$APEX_REPO_STABLE:$version\`."
}

cmd_promote_tag() {
    (($# == 1)) || die "usage: publish.sh promote-tag DIGEST"
    local digest=$1 labels version revision rc=0
    require_keys release release-backup
    labels=$(candidate_labels "$digest")
    version=${labels% *} revision=${labels#* }
    check_increases "$APEX_REPO_STABLE:$APEX_FEDORA" "$digest" "$version" "$revision" || rc=$?
    case $rc in
        0) verified_copy "$APEX_REPO_STABLE@$digest" "$APEX_REPO_STABLE:$APEX_FEDORA" ;;
        "$TAG_ALREADY_THERE") ;;
        *) return "$rc" ;;
    esac
    summary "\`$APEX_REPO_STABLE:$APEX_FEDORA\` -> \`$digest\` ($version)"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        sign | tag-testing | promote-copy | promote-tag | version) require skopeo jq ;;
        *) usage ;;
    esac
    case $cmd in
        sign) cmd_sign "$@" ;;
        tag-testing) cmd_tag_testing "$@" ;;
        promote-copy) cmd_promote_copy "$@" ;;
        promote-tag) cmd_promote_tag "$@" ;;
        version) candidate_version "$@" ;;
        *) usage ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
