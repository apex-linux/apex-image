#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Assemble, inspect, rechunk and push the Apex image (ADR 0013, image.yml). Every step
# is a subcommand so that CI can record disk usage between them; the builder VM runs
# the same steps (`just image`). Rootful podman throughout (sudo when not root).
#
#   image.sh context [--rpms-ref REF|--rpms-dir DIR] [--libfprint-ref REF|--libfprint-dir DIR]
#                    [--lock FILE]    put the RPM inputs into the context; FILE (a lock.txt
#                                     of an earlier build) is replayed through --build-arg LOCK
#   image.sh build                    podman build image/Containerfile -> localhost/apex:build
#   image.sh inspect                  manifest.json, lock list, degraded, content key
#   image.sh unchanged                exit 0 when the content key equals apex-testing:45's
#   image.sh rechunk                  rpm-ostree build-chunked-oci into an OCI layout
#   image.sh push                     push the layout as apex-testing:sha-<git12>-<run>
#   image.sh replay-check RUN_ID      exit 0 only when image.yml run RUN_ID may supply a
#                                     lock list (lib.sh replay_run_ok; needs gh, GH_TOKEN)
#
# State lives in APEX_WORK (default _build/image): build.env, manifest.json, lock.txt,
# image.env (degraded, content key), digest. The OCI layout and the rechunk work tree go
# to APEX_SCRATCH (ci-host.sh storage sets it on runners; default APEX_WORK).
#
# Environment:
#   APEX_RUN_NUMBER   the last version field (default GITHUB_RUN_NUMBER, else 0)
#   APEX_RPMS_KEY, APEX_LIBFPRINT_KEY   input keys for the content key (the context
#                     step records them from the artifacts when unset)
#   APEX_COMPOSE      passed as --build-arg COMPOSE (spike.yml: build-rootfs or dnf)
#   APEX_TARGET       podman build --target (spike.yml builds only the builder stage)
#   APEX_RELEASE_BUILD  --build-arg RELEASE_BUILD (default 0). image-build.yml sets 1 for
#                     images it pushes: the Containerfile then requires real public keys
#                     (image/checks/keys.sh), since the pushed digest is what gets promoted.
#
# Fedora bases: ARG BASE and ARG REPOS_BASE must be digest pins on
# registry.fedoraproject.org (lib.sh is_fedora_pin). quay.io stops serving a Fedora
# digest about a day after Fedora moves the tag, so a pin there is refused.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${APEX_WORK:=$APEX_ROOT/_build/image}"
: "${APEX_SCRATCH:=$APEX_WORK}"
readonly IMAGE=localhost/apex:build
# The build context is the repository root; the Containerfile's repos stage turns the
# RPMs in its rpms/ directory into the local priority-1 repository (image/packages/apex.txt).
readonly CONTEXT=$APEX_ROOT
readonly RPMS_DIR=$CONTEXT/rpms
readonly OCI_REF=apex

podman_() { as_root podman "$@"; }

load_env() {
    local f
    for f in "$@"; do
        [[ -f $APEX_WORK/$f ]] || die "missing $APEX_WORK/$f; run the earlier image.sh steps first"
        # shellcheck disable=SC1090 # written by this script
        . "$APEX_WORK/$f"
    done
}

# ---------------------------------------------------------------------------------------

cmd_context() {
    local rpms_ref="" rpms_dir="" fp_ref="" fp_dir="" lock=""
    while (($#)); do
        case $1 in
            --rpms-ref) rpms_ref=$2; shift 2 ;;
            --rpms-dir) rpms_dir=$2; shift 2 ;;
            --libfprint-ref) fp_ref=$2; shift 2 ;;
            --libfprint-dir) fp_dir=$2; shift 2 ;;
            --lock) lock=$2; shift 2 ;;
            *) die "context: unknown option $1" ;;
        esac
    done
    [[ -n $rpms_ref || -n $rpms_dir ]] || die "context: the apex RPMs are required (--rpms-ref or --rpms-dir)"
    mkdir -p "$APEX_WORK"
    rm -rf "$RPMS_DIR"
    mkdir -p "$RPMS_DIR"

    local rpms_key=${APEX_RPMS_KEY:-} fp_key=${APEX_LIBFPRINT_KEY:-}
    if [[ -n $rpms_ref ]]; then
        "$APEX_ROOT/.github/scripts/oci-artifact.sh" pull "$rpms_ref" "$RPMS_DIR"
        [[ -n $rpms_key ]] || rpms_key=$rpms_ref
    else
        (cd "$rpms_dir" && sha256sum --check --strict --quiet SHA256SUMS) || die "$rpms_dir: bad SHA256SUMS"
        cp -- "$rpms_dir"/*.rpm "$RPMS_DIR/"
        [[ -n $rpms_key || ! -f $rpms_dir/KEY ]] || rpms_key=$(cat "$rpms_dir/KEY")
    fi

    if [[ -n $fp_ref ]]; then
        "$APEX_ROOT/.github/scripts/oci-artifact.sh" pull "$fp_ref" "$RPMS_DIR"
        [[ -n $fp_key ]] || fp_key=$fp_ref
    elif [[ -n $fp_dir ]] && compgen -G "$fp_dir/*.rpm" >/dev/null; then
        (cd "$fp_dir" && sha256sum --check --strict --quiet SHA256SUMS) || die "$fp_dir: bad SHA256SUMS"
        cp -- "$fp_dir"/*.rpm "$RPMS_DIR/"
        [[ -n $fp_key || ! -f $fp_dir/key.txt ]] || fp_key=$(cat "$fp_dir/key.txt")
    else
        # ADR 0006: no patched build, so the compose installs Fedora's stock libfprint and
        # the final stage records degraded=fingerprint in manifest.json.
        warn "no patched libfprint: the image will use Fedora's stock libfprint (degraded=fingerprint)"
        fp_key=degraded
    fi

    rm -f "$APEX_WORK/replay.lock"
    if [[ -n $lock ]]; then
        [[ -s $lock ]] || die "lock file $lock is empty"
        # One NEVRA per line; the Containerfile takes them space-separated in ARG LOCK.
        grep -Eqv '^[A-Za-z0-9._+-]+-([0-9]+:)?[A-Za-z0-9._+~^-]+-[A-Za-z0-9._+~^]+\.[A-Za-z0-9_]+$' "$lock" &&
            die "lock file $lock has lines that are not NEVRAs"
        cp -- "$lock" "$APEX_WORK/replay.lock"
        log "replaying $(wc -l <"$lock") locked NEVRAs"
    fi

    (cd "$RPMS_DIR" && sha256sum -- *.rpm >SHA256SUMS)
    {
        printf 'RPMS_KEY=%q\n' "${rpms_key:-unknown}"
        printf 'LIBFPRINT_KEY=%q\n' "${fp_key:-unknown}"
        printf 'REPLAY_LOCK=%q\n' "$([[ -n $lock ]] && echo 1 || echo 0)"
    } >"$APEX_WORK/inputs.env"
    summary "### Build inputs" "" '```' "$(cat "$RPMS_DIR/SHA256SUMS")" '```'
}

cmd_build() {
    require podman git sha256sum
    mkdir -p "$APEX_WORK"
    [[ -f $APEX_WORK/inputs.env ]] || die "run 'image.sh context' first"
    local base repos_base version revision ga run
    base=$(containerfile_arg BASE)
    is_fedora_pin "$base" ||
        die "ARG BASE in image/Containerfile must be a digest pin on registry.fedoraproject.org (registry.fedoraproject.org/<repo>[:tag]@sha256:...), got '$base'"
    repos_base=$(containerfile_arg REPOS_BASE)
    is_fedora_pin "$repos_base" ||
        die "ARG REPOS_BASE in image/Containerfile must be a digest pin on registry.fedoraproject.org (registry.fedoraproject.org/<repo>[:tag]@sha256:...), got '$repos_base'"
    run=${APEX_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}
    [[ $run =~ ^[0-9]+$ ]] || die "invalid run number '$run'"
    version="$APEX_FEDORA.$(date -u +%Y%m%d).$run"
    revision=$(git -c safe.directory="$APEX_ROOT" -C "$APEX_ROOT" rev-parse HEAD)
    ga=$(ga_reached)
    {
        printf 'BASE=%q\nAPEX_VERSION=%q\nAPEX_REVISION=%q\nGA_REACHED=%q\n' \
            "$base" "$version" "$revision" "$ga"
        printf 'CREATED=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$APEX_WORK/build.env"

    group "Pull base images"
    local ref
    while IFS= read -r ref; do
        retry 5 20 podman_ pull --quiet "$ref" >/dev/null
    done < <(containerfile_from_images "$APEX_CONTAINERFILE" "BASE=$base" "REPOS_BASE=$repos_base")
    endgroup

    local -a args=(
        --build-arg "BASE=$base"
        --build-arg "REPOS_BASE=$repos_base"
        --build-arg "APEX_VERSION=$version"
        --build-arg "APEX_REVISION=$revision"
        --build-arg "GA_REACHED=$ga"
        --build-arg "RELEASE_BUILD=${APEX_RELEASE_BUILD:-0}"
    )
    [[ ${APEX_RELEASE_BUILD:-0} == 0 || ${APEX_RELEASE_BUILD:-0} == 1 ]] || die "APEX_RELEASE_BUILD must be 0 or 1"
    if [[ -f $APEX_WORK/replay.lock ]]; then
        args+=(--build-arg "LOCK=$(paste -sd' ' "$APEX_WORK/replay.lock")")
    fi
    [[ -z ${APEX_COMPOSE:-} ]] || args+=(--build-arg "COMPOSE=$APEX_COMPOSE")
    [[ -z ${APEX_TARGET:-} ]] || args+=(--target "$APEX_TARGET")

    group "podman build ($version)"
    # The flag set proven for build-rootfs on Ubuntu runners (ADR 0013). No secrets are
    # passed: this job holds none.
    podman_ build --pull=missing --layers=false \
        --cap-add=SYS_ADMIN,NET_ADMIN --device /dev/fuse \
        --security-opt seccomp=unconfined --security-opt label=disable \
        "${args[@]}" -f "$APEX_CONTAINERFILE" -t "$IMAGE" "$CONTEXT"
    endgroup
    podman_ image prune --force >/dev/null
    summary "Built \`$IMAGE\` $version from \`$base\` (GA_REACHED=$ga," \
        "RELEASE_BUILD=${APEX_RELEASE_BUILD:-0}$([[ -f $APEX_WORK/replay.lock ]] && echo ', lock replay'))"
}

# shellcheck disable=SC2153 # BASE, RPMS_KEY, ... come from load_env
cmd_inspect() {
    require podman jq git sha256sum
    load_env build.env inputs.env
    podman_ run --rm --net=none --entrypoint /usr/bin/cat "$IMAGE" /usr/share/apex/manifest.json \
        >"$APEX_WORK/manifest.json"
    jq -e --arg v "$APEX_VERSION" --arg r "$APEX_REVISION" --argjson f "$APEX_FEDORA" \
        '.schema == 1 and .name == "apex" and .version == $v and .revision == $r and .fedora == $f
         and (.packages | type == "array" and length > 0) and (.degraded | type == "array")' \
        "$APEX_WORK/manifest.json" >/dev/null ||
        die "manifest.json does not match the build ($APEX_VERSION, $APEX_REVISION) or the contract (M1 §3)"

    local degraded key
    degraded=$(jq -r '.degraded | sort | join(",")' "$APEX_WORK/manifest.json")
    # Lock list for replay (build-rootfs --lock takes NEVRAs).
    manifest_lock_list <"$APEX_WORK/manifest.json" >"$APEX_WORK/lock.txt"

    # Content key: what the image contains, independent of when it was built. A scheduled
    # build with the key of the current apex-testing:45 publishes nothing.
    local git_=(git -c safe.directory="$APEX_ROOT" -C "$APEX_ROOT")
    key=$({
        printf 'apex content key schema 1\n'
        printf 'base %s\n' "$BASE"
        printf 'degraded %s\n' "$degraded"
        printf 'rpms %s\n' "$RPMS_KEY"
        printf 'libfprint %s\n' "$LIBFPRINT_KEY"
        printf 'tree image %s\n' "$("${git_[@]}" rev-parse HEAD:image 2>/dev/null || echo none)"
        printf 'tree hardware %s\n' "$("${git_[@]}" rev-parse HEAD:hardware 2>/dev/null || echo none)"
        jq -cS '[.packages[] | {name, epoch, version, release, arch}]' "$APEX_WORK/manifest.json"
    } | sha256sum | cut -c1-64)

    printf 'DEGRADED=%q\nCONTENT_KEY=%q\n' "$degraded" "$key" >"$APEX_WORK/image.env"
    summary "Manifest: $(jq '.packages | length' "$APEX_WORK/manifest.json") packages;" \
        "degraded: \`${degraded:-none}\`; content key \`$key\`"
    set_output version "$APEX_VERSION"
    set_output degraded "$degraded"
    set_output content-key "$key"
}

cmd_unchanged() {
    require skopeo jq
    load_env image.env
    local current rc=0
    current=$(registry_label "$APEX_REPO_TESTING:$APEX_FEDORA" "$APEX_LABEL_PREFIX.content-key") || rc=$?
    case $rc in
        0) ;;
        3) log "$APEX_REPO_TESTING:$APEX_FEDORA does not exist yet"; return 1 ;;
        *) warn "cannot read $APEX_REPO_TESTING:$APEX_FEDORA; publishing"; return 1 ;;
    esac
    if [[ $current == "$CONTENT_KEY" ]]; then
        summary "Content key \`$CONTENT_KEY\` equals \`$APEX_REPO_TESTING:$APEX_FEDORA\`: nothing to publish."
        return 0
    fi
    log "content key changed: ${current:-none} -> $CONTENT_KEY"
    return 1
}

# rechunk_once OUT TMP PREV...: one build-chunked-oci run into a clean OUT.
# shellcheck disable=SC2153 # BASE, DEGRADED, ... come from load_env
rechunk_once() {
    local out=$1 tmp=$2
    shift 2
    as_root rm -rf "$out" "$tmp"
    mkdir -p "$out" "$tmp"
    local -a auth=()
    [[ -z ${REGISTRY_AUTH_FILE:-} ]] || auth=(-v "$REGISTRY_AUTH_FILE:/run/containers/0/auth.json:ro,z")
    # rpm-ostree comes from the digest-pinned builder base, never from the image under
    # construction. /var/tmp holds its temporary ostree repo (a full copy), so it goes
    # to the scratch filesystem next to the output.
    podman_ run --rm --privileged --pull=never --security-opt label=disable \
        --mount "type=image,source=$IMAGE,target=/apex-rootfs" \
        -v "$out:/out:z" -v "$tmp:/var/tmp:z" "${auth[@]}" \
        --entrypoint /usr/bin/rpm-ostree "$BASE" \
        compose build-chunked-oci --bootc --format-version=2 --max-layers 127 \
        --rootfs /apex-rootfs "$@" \
        --label "org.opencontainers.image.version=$APEX_VERSION" \
        --label "org.opencontainers.image.revision=$APEX_REVISION" \
        --label "org.opencontainers.image.source=$APEX_SOURCE_URL" \
        --label "org.opencontainers.image.created=$CREATED" \
        --label "$APEX_LABEL_PREFIX.degraded=$DEGRADED" \
        --label "$APEX_LABEL_PREFIX.content-key=$CONTENT_KEY" \
        --label "$APEX_LABEL_PREFIX.fedora=$APEX_FEDORA" \
        --output "oci:/out/$OCI_REF:latest"
}

cmd_rechunk() {
    require podman skopeo jq
    load_env build.env image.env
    local out="$APEX_SCRATCH/oci" tmp="$APEX_SCRATCH/rechunk-tmp" rc=0

    # Keep yesterday's layer plan so a daily update downloads only what changed. Best
    # effort: the first build, or an unreadable registry, rechunks from scratch.
    local -a prev=()
    registry_digest "$APEX_REPO_TESTING:$APEX_FEDORA" >/dev/null || rc=$?
    case $rc in
        0) prev=(--previous-build "docker://$APEX_REPO_TESTING:$APEX_FEDORA") ;;
        3) notice "no $APEX_REPO_TESTING:$APEX_FEDORA yet: rechunking without --previous-build" ;;
        *) warn "cannot read $APEX_REPO_TESTING:$APEX_FEDORA: rechunking without --previous-build" ;;
    esac

    group "rpm-ostree compose build-chunked-oci"
    # Retried once from a clean output: --previous-build reads the registry, and a lost
    # connection there should not cost the whole build.
    retry 2 30 rechunk_once "$out" "$tmp" "${prev[@]}"
    endgroup
    as_root rm -rf "$tmp"
    local manifest
    manifest=$(as_root skopeo inspect --raw "oci:$out/$OCI_REF:latest")
    summary "Rechunked into $(jq '.layers | length' <<<"$manifest") layers" \
        "($([[ ${#prev[@]} -gt 0 ]] && echo 'with' || echo 'without') --previous-build)."
}

cmd_push() {
    require skopeo git
    load_env build.env
    local out="$APEX_SCRATCH/oci" run tag digestfile digest
    run=${APEX_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}
    tag="sha-${APEX_REVISION:0:12}-$run"
    digestfile=$(mktemp)
    local -a auth=()
    [[ -z ${REGISTRY_AUTH_FILE:-} ]] || auth=(--authfile "$REGISTRY_AUTH_FILE")
    # A unique, never-moving tag; channel tags move only after signing (publish.sh).
    retry 4 30 as_root skopeo copy --quiet --preserve-digests "${auth[@]}" \
        --digestfile "$digestfile" "oci:$out/$OCI_REF:latest" "docker://$APEX_REPO_TESTING:$tag"
    digest=$(as_root cat "$digestfile")
    rm -f "$digestfile"
    is_digest "$digest" || die "skopeo reported no digest"
    printf '%s\n' "$digest" >"$APEX_WORK/digest"
    set_output digest "$digest"
    set_output tag "$tag"
    summary "Pushed \`$APEX_REPO_TESTING:$tag\` = \`$digest\`"
}

cmd_replay_check() {
    (($# == 1)) || die "usage: image.sh replay-check RUN_ID"
    local id=$1 repo=${GITHUB_REPOSITORY:-$APEX_GITHUB_REPO} run
    [[ $id =~ ^[0-9]+$ ]] || die "lock-run-id must be a numeric run ID, got '$id'"
    require gh jq
    run=$(gh api "repos/$repo/actions/runs/$id") || die "cannot read run $id of $repo"
    if ! replay_run_ok "$repo" <<<"$run"; then
        local seen
        seen=$(jq -c '{path, event, head_branch, head_repository: .head_repository.full_name, status}' <<<"$run")
        die "run $id may not supply a lock list ($seen): only a finished image.yml run of" \
            "$repo's main branch (push, schedule or dispatch) is replayed"
    fi
    summary "Replaying the lock list of run $id ($(jq -r '.event + ", " + .head_sha' <<<"$run"))."
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        context) cmd_context "$@" ;;
        build) cmd_build "$@" ;;
        inspect) cmd_inspect "$@" ;;
        unchanged) cmd_unchanged "$@" ;;
        rechunk) cmd_rechunk "$@" ;;
        push) cmd_push "$@" ;;
        replay-check) cmd_replay_check "$@" ;;
        *) usage ;;
    esac
}

main "$@"
