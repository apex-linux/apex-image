#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

Sign, tag and promote Apex images. Only digests move; nothing is rebuilt.

  publish.sh sign REPO DIGEST             cosign-sign REPO@DIGEST (legacy .sig format)
  publish.sh tag-testing DIGEST VERSION   move apex-testing:45 to DIGEST
  publish.sh promote-copy [--allow-degraded] DIGEST
                                          copy apex-testing@DIGEST to apex:<version>
  publish.sh promote-tag [--allow-degraded] DIGEST
                                          move apex:45 to DIGEST
  publish.sh version DIGEST               print the candidate's version label
  publish.sh publish [--allow-degraded] OCI
                                          the builder VM's release (S1d): push the
                                          rechunked layout OCI (oci:DIR:TAG) as
                                          apex:<version>, cosign-sign it with
                                          COSIGN_KEY_FILE (default
                                          ~/.config/apex/cosign.key, COSIGN_PASSWORD), then
                                          move apex:45 to it, policy-verified
  publish.sh rehearse OCI                 the same against a throwaway registry:2 on
                                          localhost and a throwaway key; nothing leaves
                                          this host

A tag moves only to a digest that passes the image's own committed policy, with a newer
version built from the same or a later commit of main (needs fetch-depth: 0). A stable
move refuses a candidate degraded in a component apex:45 is not degraded in; only the
owner's --allow-degraded takes it.

Environment: REGISTRY_AUTH_FILE (write access for tag moves); for sign also
COSIGN_PRIVATE_KEY, COSIGN_PASSWORD, GH_TOKEN and GITHUB_ACTOR, and cosign on PATH.
EOF
    exit 2
}

readonly SYSTEM_FILES="$APEX_ROOT/image/system_files"
readonly COMMITTED_POLICY="$SYSTEM_FILES/usr/share/apex/containers/policy.json"
readonly TAG_ALREADY_THERE=10
readonly REHEARSAL_REGISTRY_IMAGE=docker.io/library/registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 # 2
readonly REHEARSAL_CONTAINER=apex-publish-rehearsal

# Set only by cmd_rehearse: its throwaway trust, never the environment's.
VERIFY_POLICY=
VERIFY_REGISTRIES_D=
declare -a COSIGN_EXTRA=()

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
    local src=$1 dst=$2 policy=$VERIFY_POLICY regd=$VERIFY_REGISTRIES_D
    [[ -n $policy ]] || policy=$(checkout_policy)
    [[ -n $regd ]] || regd=$(checkout_registries_d)
    local -a auth
    mapfile -t auth < <(skopeo_auth_args)
    log "copy (policy-verified) $src -> $dst"
    retry 3 15 skopeo --policy "$policy" --registries.d "$regd" copy --quiet \
        --preserve-digests --remove-signatures "${auth[@]}" "docker://$src" "docker://$dst"
    [[ -n $VERIFY_POLICY ]] || rm -rf "$policy" "$regd"
}

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

# The names in comma list $1 that comma list $2 lacks, comma-joined.
degraded_growth() {
    comm -23 <(tr ',' '\n' <<<"$1" | sed '/^$/d' | sort -u) <(tr ',' '\n' <<<"$2" | sed '/^$/d' | sort -u) |
        paste -sd, -
}

degraded_of() {
    jq -r --arg l "$APEX_LABEL_PREFIX.degraded" '.Labels[$l] // ""' <<<"$1"
}

# A component that degrades reaches the published channel only by the owner's decision.
check_degraded() {
    local ref=$1 digest=$2 allow=$3 json
    json=$(registry_inspect "$APEX_REPO_TESTING@$digest") || die "cannot inspect $APEX_REPO_TESTING@$digest"
    check_degraded_against "$ref" "$(degraded_of "$json")" "$allow"
}

check_degraded_against() {
    local ref=$1 candidate=$2 allow=$3 json rc=0 published='' grown
    json=$(registry_inspect "$ref") || rc=$?
    case $rc in
        0) published=$(degraded_of "$json") ;;
        "$REGISTRY_ABSENT") ;;
        *) die "cannot read $ref; refusing to move it without knowing what it has degraded" ;;
    esac
    grown=$(degraded_growth "$candidate" "$published")
    [[ -n $grown ]] || return 0
    if [[ $allow == 1 ]]; then
        warn "$ref: the candidate adds degraded=$grown (published: ${published:-none}); moving it by the owner's --allow-degraded"
        summary "Owner's override: \`$ref\` takes degraded=$grown."
        return 0
    fi
    die "refusing to move $ref: the candidate adds degraded=$grown (published: ${published:-none});" \
        "only the owner's --allow-degraded publishes it"
}

allow_degraded_arg() {
    if [[ ${1:-} == --allow-degraded ]]; then printf '1\n'; else printf '0\n'; fi
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
    local allow
    allow=$(allow_degraded_arg "$@")
    ((allow == 0)) || shift
    (($# == 1)) || die "usage: publish.sh promote-copy [--allow-degraded] DIGEST"
    local digest=$1 labels version revision rc=0 existing
    require_keys ci release release-backup
    labels=$(candidate_labels "$digest")
    version=${labels% *} revision=${labels#* }
    check_increases "$APEX_REPO_STABLE:$APEX_FEDORA" "$digest" "$version" "$revision" || rc=$?
    ((rc == 0 || rc == TAG_ALREADY_THERE)) || return "$rc"
    check_degraded "$APEX_REPO_STABLE:$APEX_FEDORA" "$digest" "$allow"
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
    local allow
    allow=$(allow_degraded_arg "$@")
    ((allow == 0)) || shift
    (($# == 1)) || die "usage: publish.sh promote-tag [--allow-degraded] DIGEST"
    local digest=$1 labels version revision rc=0
    require_keys release release-backup
    labels=$(candidate_labels "$digest")
    version=${labels% *} revision=${labels#* }
    check_increases "$APEX_REPO_STABLE:$APEX_FEDORA" "$digest" "$version" "$revision" || rc=$?
    case $rc in
        0)
            check_degraded "$APEX_REPO_STABLE:$APEX_FEDORA" "$digest" "$allow"
            verified_copy "$APEX_REPO_STABLE@$digest" "$APEX_REPO_STABLE:$APEX_FEDORA" ;;
        "$TAG_ALREADY_THERE") ;;
        *) return "$rc" ;;
    esac
    summary "\`$APEX_REPO_STABLE:$APEX_FEDORA\` -> \`$digest\` ($version)"
}

# REPO:<version> is immutable, and REPO:45 moves only after the signature verifies.
publish_layout() {
    local repo=$1 oci=$2 allow=$3 key=$4 json digest version revision fedora degraded rc=0 existing pushed
    json=$(skopeo inspect "oci:$oci") || die "cannot inspect the layout $oci (image.sh rechunk writes it)"
    digest=$(jq -r '.Digest // ""' <<<"$json")
    version=$(jq -r '.Labels["org.opencontainers.image.version"] // ""' <<<"$json")
    revision=$(jq -r '.Labels["org.opencontainers.image.revision"] // ""' <<<"$json")
    fedora=$(jq -r --arg l "$APEX_LABEL_PREFIX.fedora" '.Labels[$l] // ""' <<<"$json")
    degraded=$(degraded_of "$json")
    is_digest "$digest" || die "the layout $oci has no manifest digest"
    version_valid "$version" || die "the layout has no valid version label (got '$version')"
    [[ $fedora == "$APEX_FEDORA" && $version == "$APEX_FEDORA".* ]] ||
        die "the layout is Fedora '$fedora' version '$version', not Fedora $APEX_FEDORA"
    [[ $revision =~ ^[0-9a-f]{40}$ ]] || die "the layout has no valid revision label (got '$revision')"

    existing=$(registry_digest "$repo:$version") || rc=$?
    case $rc in
        0) [[ $existing == "$digest" ]] || die "$repo:$version already exists as $existing; version tags are immutable" ;;
        "$REGISTRY_ABSENT")
            registry_tag_absent "$repo" "$version" ||
                die "inspect found no $repo:$version but list-tags does not confirm it; not overwriting a version tag"
            ;;
        *) die "cannot read $repo:$version" ;;
    esac
    rc=0
    check_increases "$repo:$APEX_FEDORA" "$digest" "$version" "$revision" || rc=$?
    ((rc == 0 || rc == TAG_ALREADY_THERE)) || return "$rc"
    check_degraded_against "$repo:$APEX_FEDORA" "$degraded" "$allow"

    local -a auth
    mapfile -t auth < <(skopeo_auth_args)
    pushed=$(mktemp)
    retry 4 30 skopeo copy --quiet --preserve-digests "${auth[@]}" --digestfile "$pushed" \
        "oci:$oci" "docker://$repo:$version"
    [[ $(cat "$pushed") == "$digest" ]] || die "pushed $repo:$version as $(cat "$pushed"), not the layout's $digest"
    rm -f "$pushed"
    # Legacy .sig tags, as cmd_sign: containers/image cannot verify the new bundle format yet.
    retry 3 15 cosign sign --yes --new-bundle-format=false --use-signing-config=false \
        "${COSIGN_EXTRA[@]}" --key "$key" "$repo@$digest"
    verified_copy "$repo@$digest" "$repo:$APEX_FEDORA"
    set_output version "$version"
    set_output digest "$digest"
    summary "Published \`$repo:$version\` = \`$digest\`, signed; \`$repo:$APEX_FEDORA\` moved to it after the policy verified the signature."
}

cmd_publish() {
    local allow
    allow=$(allow_degraded_arg "$@")
    ((allow == 0)) || shift
    (($# == 1)) || die "usage: publish.sh publish [--allow-degraded] oci:DIR:TAG"
    local oci=${1#oci:} key=${COSIGN_KEY_FILE:-$HOME/.config/apex/cosign.key}
    require cosign
    require_keys release release-backup
    [[ -f $key ]] || die "no cosign key $key (COSIGN_KEY_FILE): the owner makes it in the builder VM (ADR 0012)"
    publish_layout "$APEX_REPO_STABLE" "$oci" "$allow" "$key"
}

# A throwaway registry, key and policy: the signature must verify against that key alone.
cmd_rehearse() {
    (($# == 1)) || die "usage: publish.sh rehearse oci:DIR:TAG"
    local oci=${1#oci:} dir port=${APEX_REHEARSAL_PORT:-5000} repo other
    require podman cosign
    dir=$(mktemp -d)
    repo=localhost:$port/apex
    # shellcheck disable=SC2064 # expand now: the paths are local
    trap "podman rm -f $REHEARSAL_CONTAINER >/dev/null 2>&1 || true; rm -rf '$dir'" EXIT
    podman rm -f "$REHEARSAL_CONTAINER" >/dev/null 2>&1 || true
    podman run -d --rm --name "$REHEARSAL_CONTAINER" -p "127.0.0.1:$port:5000" "$REHEARSAL_REGISTRY_IMAGE" >/dev/null ||
        die "cannot start $REHEARSAL_REGISTRY_IMAGE on 127.0.0.1:$port"
    (cd "$dir" && COSIGN_PASSWORD='' cosign generate-key-pair >/dev/null) || die "cosign generate-key-pair failed"
    mkdir -p "$dir/other" "$dir/registries.d"
    (cd "$dir/other" && COSIGN_PASSWORD='' cosign generate-key-pair >/dev/null) || die "cosign generate-key-pair failed"
    printf '[[registry]]\nlocation = "localhost:%s"\ninsecure = true\n' "$port" >"$dir/registries.conf"
    export CONTAINERS_REGISTRIES_CONF=$dir/registries.conf
    printf 'docker:\n  localhost:%s:\n    use-sigstore-attachments: true\n' "$port" >"$dir/registries.d/rehearsal.yaml"
    rehearsal_policy() {
        jq -n --arg r "$repo" --arg k "$1" '{default: [{type: "reject"}], transports: {docker: {($r):
            [{type: "sigstoreSigned", keyPath: $k, signedIdentity: {type: "matchRepository"}}]}}}'
    }
    rehearsal_policy "$dir/cosign.pub" >"$dir/policy.json"
    rehearsal_policy "$dir/other/cosign.pub" >"$dir/other/policy.json"
    VERIFY_POLICY=$dir/policy.json
    VERIFY_REGISTRIES_D=$dir/registries.d
    COSIGN_EXTRA=(--allow-http-registry --tlog-upload=false)
    COSIGN_PASSWORD='' publish_layout "$repo" "$oci" 0 "$dir/cosign.key"
    other=$(registry_digest "$repo:$APEX_FEDORA") || die "the rehearsal left no $repo:$APEX_FEDORA"
    if skopeo --policy "$dir/other/policy.json" --registries.d "$dir/registries.d" copy --quiet \
        "docker://$repo:$APEX_FEDORA" "oci:$dir/check:x" >/dev/null 2>&1; then
        die "a policy trusting another key accepted $repo:$APEX_FEDORA: the signature was never checked"
    fi
    summary "Rehearsal: $repo:$APEX_FEDORA = \`$other\`; a policy with another key refuses it."
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        sign | tag-testing | promote-copy | promote-tag | version | publish | rehearse) require skopeo jq ;;
        *) usage ;;
    esac
    case $cmd in
        publish) cmd_publish "$@" ;;
        rehearse) cmd_rehearse "$@" ;;
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
