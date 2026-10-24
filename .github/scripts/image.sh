#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

Assemble, inspect, rechunk and push the Apex image, with rootful podman (sudo when not
root).

  image.sh context --rpms-ref REF|--rpms-dir DIR --desktop-ref REF|--desktop-dir DIR
                   [--libfprint-ref REF|--libfprint-dir DIR] --lane-lock LANE [--lock FILE]
                   [--kernel fedora]
                                    put the RPM inputs into the context: the apex RPM
                                    (apex-system's rpms.sh), apex-desktop (apex-desktop's)
                                    and libfprint (apex-kernel's); LANE is the rebuild
                                    lane's lock in its store (the builder VM's
                                    ~/apex-store/rpms.lock.next); FILE (a lock.txt of an
                                    earlier build) is replayed through --build-arg LOCK;
                                    --kernel fedora is the break-glass image: Fedora's
                                    kernel, the pair's rpm lines left out of the image's
                                    lock (degraded=nvidia); it never promotes
  image.sh build                    podman build image/Containerfile -> localhost/apex:build
  image.sh inspect                  manifest.json, lock list, degraded, held, content key
  image.sh unchanged                exit 0 when the content key equals apex-testing:45's
  image.sh rechunk                  rpm-ostree build-chunked-oci into an OCI layout
  image.sh push                     push the layout as apex-testing:sha-<git12>-<run>
  image.sh replay-check RUN_ID      exit 0 only when image.yml run RUN_ID may supply a
                                    lock list (needs gh, GH_TOKEN)

Environment:
  APEX_WORK         the state: build.env, manifest.json, lock.txt, image.env, digest
                    (default _build/image)
  APEX_SCRATCH      the OCI layout and the rechunk work tree (default APEX_WORK)
  APEX_RUN_NUMBER   the last version field (default GITHUB_RUN_NUMBER, else 0)
  APEX_RPMS_KEY, APEX_DESKTOP_KEY, APEX_LIBFPRINT_KEY   input keys for the content
                    key (the context step records them from the artifacts when unset)
  APEX_COMPOSE      passed as --build-arg COMPOSE (build-rootfs or dnf)
  APEX_TARGET       podman build --target (a stage of image/Containerfile)
  APEX_RELEASE_BUILD  --build-arg RELEASE_BUILD (default 0); 1 for an image that will
                    be pushed, which then requires the real public keys
  APEX_LANE_RECIPES the checkouts holding packaging/pkgs, ':'-separated (default
                    this checkout)
  APEX_SYSTEM_SRC, APEX_DESKTOP_SRC   the apex-system and apex-desktop checkouts
                    (default this checkout)
EOF
    exit 2
}

: "${APEX_WORK:=$APEX_ROOT/_build/image}"
: "${APEX_SCRATCH:=$APEX_WORK}"
readonly IMAGE=localhost/apex:build
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

lane_families() {
    local root f
    local -a roots
    IFS=: read -ra roots <<<"${APEX_LANE_RECIPES:-$APEX_ROOT}"
    for root in "${roots[@]}"; do
        for f in "$root"/packaging/pkgs/*/pkg.env; do
            [[ -f $f ]] || continue
            sed -n 's/^family=[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' "$f"
        done
    done | LC_ALL=C sort -u
}

head_tree() { git -c safe.directory="$1" -C "$1" rev-parse "HEAD:$2" 2>/dev/null || echo none; }

# Prints "PATH SHA256" per rpm line, and only when the lock is valid and records every family.
lane_lock_check() {
    local lock=$1
    shift
    [[ -f $lock ]] || { log "no lane lock $lock"; return 1; }
    [[ $(head -n 1 -- "$lock") == '# apex rpms.lock 1:'* ]] ||
        { log "$lock is not an rpms.lock of format 1 (its first line)"; return 1; }
    awk -v want="$*" '
        function bad(msg) { printf "%s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"; failed = 1; exit 1 }
        /^#/ || NF == 0 { next }
        $1 == "family" {
            if (NF < 4) bad("a family line is: family NAME STATE KEY [ATTR...]")
            if ($2 !~ /^[a-z0-9][a-z0-9._+-]*$/) bad("bad family name \"" $2 "\"")
            if ($2 in state) bad("family " $2 " appears twice")
            if ($3 !~ /^(built|held|stock|degraded)$/) bad("family " $2 ": unknown state " $3)
            state[$2] = $3
            order[++families] = $2
            next
        }
        $1 == "rpm" {
            if (NF != 7) bad("an rpm line is: rpm FAMILY KIND NAME NEVRA SHA256 PATH")
            if (!($2 in state)) bad("an rpm line of " $2 " comes before its family line, or it has none")
            if (state[$2] != "built" && state[$2] != "held") bad("family " $2 " is " state[$2] ", but has rpm lines")
            if ($3 != "built" && $3 != "mirror") bad("unknown rpm kind " $3)
            name = $4; nevra = $5; rest = substr(nevra, length(name) + 2)
            if (index(nevra, name "-") != 1 || rest !~ /^[0-9]+:[^-:]+-[^-]+\.[A-Za-z0-9_]+$/)
                bad(nevra " is not a NEVRA of " name)
            if (length($6) != 64 || $6 ~ /[^0-9a-f]/) bad("bad sha256 for " nevra)
            sub(/^[0-9]+:/, "", rest)
            file = $7; sub(/^.*\//, "", file)
            if ($7 ~ /^\// || $7 ~ /(^|\/)\.\.(\/|$)/ || file != name "-" rest ".rpm")
                bad("the store path " $7 " is not " name "-" rest ".rpm below the store")
            if (name in seen) bad("package " name " appears twice")
            seen[name] = 1
            if ($3 == "built") apex[$2]++
            print $7, $6
            next
        }
        { bad("unknown record \"" $1 "\"") }
        END {
            if (failed) exit 1
            for (i = 1; i <= families; i++) {
                f = order[i]
                if ((state[f] == "built" || state[f] == "held") && !apex[f]) {
                    printf "%s: family %s is %s, but has no Apex-built rpm line\n", FILENAME, f, state[f] > "/dev/stderr"
                    exit 1
                }
            }
            n = split(want, w, " ")
            for (i = 1; i <= n; i++) {
                if (!(w[i] in state)) {
                    printf "%s: no family %s (packaging/pkgs), so the image would silently take the Fedora build; run the lane, or choose stock (just pkg-stock)\n", FILENAME, w[i] > "/dev/stderr"
                    exit 1
                }
            }
        }' "$lock"
}

lane_lock_states() {
    awk -v s="$2" '$1 == "family" && $3 == s { print $2 }' "$1" | LC_ALL=C sort | paste -sd, -
}

# The kernel pair's set also holds what the image checks it against: apex-kernel's
# config-required.txt and negativo17's key as the lane verified it.
lane_pair_context() {
    local lane=$1 store=$2 dir
    dir=$(awk '$1 == "rpm" && $2 == "kernel-cachyos" { sub(/\/[^\/]*$/, "", $7); print $7; exit }' "$lane")
    [[ -n $dir ]] || return 0
    [[ ! -e $RPMS_DIR/pair ]] || die "$RPMS_DIR/pair exists twice: the lane and another input both provide it"
    mkdir -p -- "$RPMS_DIR/pair"
    [[ -f $store/$dir/config-required.txt ]] || die "the kernel pair's set $store/$dir has no config-required.txt"
    cp -- "$store/$dir/config-required.txt" "$RPMS_DIR/pair/"
    if awk '$1 == "rpm" && $2 == "kernel-cachyos" && $3 == "mirror" { f = 1 } END { exit !f }' "$lane"; then
        [[ -s $store/$dir/negativo17.gpg ]] || die "the kernel pair's set $store/$dir has no negativo17.gpg for its userspace"
        cp -- "$store/$dir/negativo17.gpg" "$RPMS_DIR/pair/"
    fi
    log "lane: the kernel pair from $dir"
}

# The image's copy of LANE with the kernel pair as the owner's stock choice: Fedora's kernel,
# no rpm lines. The store's lock is never touched.
break_glass_lock() {
    awk '!(($1 == "family" || $1 == "rpm") && $2 == "kernel-cachyos")' "$1"
    printf '%s\n' "family kernel-cachyos stock - reason=break-glass: just image KERNEL=fedora, Fedora's kernel without the NVIDIA set"
}

lane_context() {
    local lane=$1 kernel=${2:-pair} store path sha dest n=0
    local -a families
    mapfile -t families < <(lane_families)
    store=$(cd "$(dirname -- "$lane")" && pwd)
    if [[ $kernel == fedora ]]; then
        awk '$1 == "family" && $2 == "kernel-cachyos" { f = 1 } END { exit !f }' "$lane" ||
            die "context --kernel fedora: no kernel pair in the lane lock $lane: the image already uses Fedora's kernel"
        break_glass_lock "$lane" >"$APEX_WORK/break-glass.lock"
        lane=$APEX_WORK/break-glass.lock
        warn "break-glass: Fedora's kernel, without the kernel pair or its NVIDIA set (degraded=nvidia); this image never promotes"
    fi
    local list
    list=$(lane_lock_check "$lane" "${families[@]}") || die "lane lock $lane is not usable (see above)"
    while read -r path sha; do
        [[ -n $path ]] || continue
        dest=$RPMS_DIR/${path##*/}
        [[ ! -e $dest ]] || die "$dest exists twice: the lane and another RPM input both provide it"
        [[ -f $store/$path ]] || die "the lane store has no $store/$path"
        [[ $(sha256sum <"$store/$path" | cut -d' ' -f1) == "$sha" ]] ||
            die "$store/$path does not match its sha256 in $lane"
        cp -- "$store/$path" "$dest"
        n=$((n + 1))
    done <<<"$list"
    cp -- "$lane" "$RPMS_DIR/rpms.lock"
    lane_pair_context "$lane" "$store"
    local held stock degraded
    held=$(lane_lock_states "$lane" held)
    stock=$(lane_lock_states "$lane" stock)
    degraded=$(lane_lock_states "$lane" degraded)
    log "lane: $n RPM(s) from $store (families: ${families[*]:-none}; held: ${held:-none}; stock: ${stock:-none})"
    [[ -z $held ]] || warn "lane: held at the last good build: $held (just pkg-status shows the reason and the limit)"
    [[ -z $stock ]] || warn "lane: Fedora's build by the owner's choice: $stock"
    [[ -z $degraded ]] || warn "lane: degraded to Fedora's build: $degraded"
}

cmd_context() {
    local rpms_ref="" rpms_dir="" desktop_ref="" desktop_dir="" fp_ref="" fp_dir="" lock="" lane="" kernel=pair
    while (($#)); do
        case $1 in
            --rpms-ref) rpms_ref=$2; shift 2 ;;
            --rpms-dir) rpms_dir=$2; shift 2 ;;
            --desktop-ref) desktop_ref=$2; shift 2 ;;
            --desktop-dir) desktop_dir=$2; shift 2 ;;
            --libfprint-ref) fp_ref=$2; shift 2 ;;
            --libfprint-dir) fp_dir=$2; shift 2 ;;
            --lane-lock) lane=$2; shift 2 ;;
            --lock) lock=$2; shift 2 ;;
            --kernel)
                [[ ${2:-} == fedora ]] || die "context: --kernel takes fedora, the break-glass image"
                kernel=fedora
                shift 2
                ;;
            *) die "context: unknown option $1" ;;
        esac
    done
    [[ -n $rpms_ref || -n $rpms_dir ]] || die "context: the apex RPM is required (--rpms-ref or --rpms-dir)"
    [[ -n $desktop_ref || -n $desktop_dir ]] || die "context: apex-desktop is required (--desktop-ref or --desktop-dir)"
    [[ -n $lane ]] || die "context: the rebuild lane's lock is required (--lane-lock; in the builder VM" \
        "$HOME/apex-store/rpms.lock.next): gnome-shell reaches the image only through it, and nothing" \
        "degrades a design package to stock on its own (ADR 0014)"
    mkdir -p "$APEX_WORK"
    rm -rf "$RPMS_DIR"
    mkdir -p "$RPMS_DIR"

    local rpms_key=${APEX_RPMS_KEY:-} fp_key=${APEX_LIBFPRINT_KEY:-} desktop_key=${APEX_DESKTOP_KEY:-}
    if [[ -n $rpms_ref ]]; then
        "$APEX_ROOT/.github/scripts/oci-artifact.sh" pull "$rpms_ref" "$RPMS_DIR"
        [[ -n $rpms_key ]] || rpms_key=$rpms_ref
    else
        (cd "$rpms_dir" && sha256sum --check --strict --quiet SHA256SUMS) || die "$rpms_dir: bad SHA256SUMS"
        cp -- "$rpms_dir"/*.rpm "$RPMS_DIR/"
        [[ -n $rpms_key || ! -f $rpms_dir/KEY ]] || rpms_key=$(cat "$rpms_dir/KEY")
    fi

    if [[ -n $desktop_ref ]]; then
        "$APEX_ROOT/.github/scripts/oci-artifact.sh" pull "$desktop_ref" "$RPMS_DIR"
        [[ -n $desktop_key ]] || desktop_key=$desktop_ref
    else
        (cd "$desktop_dir" && sha256sum --check --strict --quiet SHA256SUMS) || die "$desktop_dir: bad SHA256SUMS"
        cp -- "$desktop_dir"/*.rpm "$RPMS_DIR/"
        [[ -n $desktop_key || ! -f $desktop_dir/KEY ]] || desktop_key=$(cat "$desktop_dir/KEY")
    fi

    if [[ -n $fp_ref ]]; then
        "$APEX_ROOT/.github/scripts/oci-artifact.sh" pull "$fp_ref" "$RPMS_DIR"
        [[ -n $fp_key ]] || fp_key=$fp_ref
    elif [[ -n $fp_dir ]] && compgen -G "$fp_dir/*.rpm" >/dev/null; then
        (cd "$fp_dir" && sha256sum --check --strict --quiet SHA256SUMS) || die "$fp_dir: bad SHA256SUMS"
        cp -- "$fp_dir"/*.rpm "$RPMS_DIR/"
        [[ -n $fp_key || ! -f $fp_dir/key.txt ]] || fp_key=$(cat "$fp_dir/key.txt")
    else
        warn "no patched libfprint: the image will use Fedora's stock libfprint (degraded=fingerprint)"
        fp_key=degraded
    fi

    rm -f "$APEX_WORK/replay.lock"
    if [[ -n $lock ]]; then
        [[ -s $lock ]] || die "lock file $lock is empty"
        grep -Eqv '^[A-Za-z0-9._+-]+-([0-9]+:)?[A-Za-z0-9._+~^-]+-[A-Za-z0-9._+~^]+\.[A-Za-z0-9_]+$' "$lock" &&
            die "lock file $lock has lines that are not NEVRAs"
        cp -- "$lock" "$APEX_WORK/replay.lock"
        log "replaying $(wc -l <"$lock") locked NEVRAs"
    fi

    lane_context "$lane" "$kernel"

    if [[ ! $APEX_SYSTEM_SRC -ef $APEX_ROOT ]]; then
        [[ -z $(git -c safe.directory="$APEX_ROOT" -C "$APEX_ROOT" ls-files -- hardware) ]] ||
            die "context: this checkout tracks hardware/, so APEX_SYSTEM_SRC must be unset or this checkout"
        rm -rf "$CONTEXT/hardware"
        mkdir -p "$CONTEXT/hardware/m7400qc"
        cp -R -- "$APEX_SYSTEM_SRC/hardware/m7400qc/generated" "$CONTEXT/hardware/m7400qc/"
    fi

    (cd "$RPMS_DIR" && sha256sum -- *.rpm >SHA256SUMS)
    {
        printf 'RPMS_KEY=%q\n' "${rpms_key:-unknown}"
        printf 'DESKTOP_KEY=%q\n' "${desktop_key:-unknown}"
        printf 'LIBFPRINT_KEY=%q\n' "${fp_key:-unknown}"
        printf 'LANE_LOCK_SHA256=%q\n' "$(sha256sum <"$RPMS_DIR/rpms.lock" | cut -d' ' -f1)"
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
        # bootc install copies this label into its aleph, and bootupd 0.3 fails
        # `bootupctl update` on an aleph without a version.
        --label "org.opencontainers.image.version=$version"
    )
    [[ ${APEX_RELEASE_BUILD:-0} == 0 || ${APEX_RELEASE_BUILD:-0} == 1 ]] || die "APEX_RELEASE_BUILD must be 0 or 1"
    if [[ -f $APEX_WORK/replay.lock ]]; then
        args+=(--build-arg "LOCK=$(paste -sd' ' "$APEX_WORK/replay.lock")")
    fi
    [[ -z ${APEX_COMPOSE:-} ]] || args+=(--build-arg "COMPOSE=$APEX_COMPOSE")
    [[ -z ${APEX_TARGET:-} ]] || args+=(--target "$APEX_TARGET")

    group "podman build ($version)"
    # The privileges build-rootfs needs inside the build.
    podman_ build --pull=missing --layers=false \
        --cap-add=SYS_ADMIN,NET_ADMIN --device /dev/fuse \
        --security-opt seccomp=unconfined --security-opt label=disable \
        "${args[@]}" -f "$APEX_CONTAINERFILE" -t "$IMAGE" "$CONTEXT"
    endgroup
    podman_ image prune --force >/dev/null
    summary "Built \`$IMAGE\` $version from \`$base\` (GA_REACHED=$ga," \
        "RELEASE_BUILD=${APEX_RELEASE_BUILD:-0}$([[ -f $APEX_WORK/replay.lock ]] && echo ', lock replay'))"
}

# No build time goes in, so a rebuild of unchanged inputs publishes nothing.
# shellcheck disable=SC2153 # BASE, RPMS_KEY, ... come from load_env
content_key() {
    local degraded=$1 held=$2
    {
        printf 'apex content key schema 1\n'
        printf 'base %s\n' "$BASE"
        printf 'degraded %s\n' "$degraded"
        printf 'held %s\n' "$held"
        printf 'rpms %s\n' "$RPMS_KEY"
        printf 'desktop-rpm %s\n' "$DESKTOP_KEY"
        printf 'libfprint %s\n' "$LIBFPRINT_KEY"
        printf 'lane %s\n' "$LANE_LOCK_SHA256"
        printf 'tree image %s\n' "$(head_tree "$APEX_ROOT" image)"
        printf 'tree desktop %s\n' "$(head_tree "$APEX_DESKTOP_SRC" desktop)"
        printf 'tree hardware %s\n' "$(head_tree "$APEX_SYSTEM_SRC" hardware)"
        jq -cS '[.packages[] | {name, epoch, version, release, arch}]' "$APEX_WORK/manifest.json"
    } | sha256sum | cut -c1-64
}

cmd_inspect() {
    require podman jq git sha256sum
    load_env build.env inputs.env
    podman_ run --rm --net=none --entrypoint /usr/bin/cat "$IMAGE" /usr/share/apex/manifest.json \
        >"$APEX_WORK/manifest.json"
    jq -e --arg v "$APEX_VERSION" --arg r "$APEX_REVISION" --argjson f "$APEX_FEDORA" \
        '.schema == 1 and .name == "apex" and .version == $v and .revision == $r and .fedora == $f
         and (.packages | type == "array" and length > 0) and (.degraded | type == "array")
         and (.held | type == "array")' \
        "$APEX_WORK/manifest.json" >/dev/null ||
        die "manifest.json does not match the build ($APEX_VERSION, $APEX_REVISION) or manifest schema 1"

    local degraded held key
    degraded=$(jq -r '.degraded | sort | join(",")' "$APEX_WORK/manifest.json")
    held=$(jq -r '.held | sort | join(",")' "$APEX_WORK/manifest.json")
    manifest_lock_list <"$APEX_WORK/manifest.json" >"$APEX_WORK/lock.txt"
    key=$(content_key "$degraded" "$held")

    printf 'DEGRADED=%q\nHELD=%q\nCONTENT_KEY=%q\n' "$degraded" "$held" "$key" >"$APEX_WORK/image.env"
    summary "Manifest: $(jq '.packages | length' "$APEX_WORK/manifest.json") packages;" \
        "degraded: \`${degraded:-none}\`; held: \`${held:-none}\`; content key \`$key\`"
    set_output version "$APEX_VERSION"
    set_output degraded "$degraded"
    set_output held "$held"
    set_output content-key "$key"
}

cmd_unchanged() {
    require skopeo jq
    load_env image.env
    local current rc=0
    current=$(registry_label "$APEX_REPO_TESTING:$APEX_FEDORA" "$APEX_LABEL_PREFIX.content-key") || rc=$?
    case $rc in
        0) ;;
        "$REGISTRY_ABSENT") log "$APEX_REPO_TESTING:$APEX_FEDORA does not exist yet"; return 1 ;;
        *) warn "cannot read $APEX_REPO_TESTING:$APEX_FEDORA; publishing"; return 1 ;;
    esac
    if [[ $current == "$CONTENT_KEY" ]]; then
        summary "Content key \`$CONTENT_KEY\` equals \`$APEX_REPO_TESTING:$APEX_FEDORA\`: nothing to publish."
        return 0
    fi
    log "content key changed: ${current:-none} -> $CONTENT_KEY"
    return 1
}

# shellcheck disable=SC2153 # BASE, DEGRADED, HELD, ... come from load_env
rechunk_once() {
    local out=$1 tmp=$2
    shift 2
    as_root rm -rf "$out" "$tmp"
    mkdir -p "$out" "$tmp"
    local -a auth=()
    [[ -z ${REGISTRY_AUTH_FILE:-} ]] || auth=(-v "$REGISTRY_AUTH_FILE:/run/containers/0/auth.json:ro,z")
    # rpm-ostree runs from the pinned builder base, never from the image under construction.
    # Its temporary ostree repo in /var/tmp is a full copy, hence the scratch filesystem.
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
        --label "$APEX_LABEL_PREFIX.held=$HELD" \
        --label "$APEX_LABEL_PREFIX.content-key=$CONTENT_KEY" \
        --label "$APEX_LABEL_PREFIX.fedora=$APEX_FEDORA" \
        --output "oci:/out/$OCI_REF:latest"
}

cmd_rechunk() {
    require podman skopeo jq
    load_env build.env image.env
    local out="$APEX_SCRATCH/oci" tmp="$APEX_SCRATCH/rechunk-tmp" rc=0

    local -a prev=()
    registry_digest "$APEX_REPO_TESTING:$APEX_FEDORA" >/dev/null || rc=$?
    case $rc in
        0) prev=(--previous-build "docker://$APEX_REPO_TESTING:$APEX_FEDORA") ;;
        "$REGISTRY_ABSENT") notice "no $APEX_REPO_TESTING:$APEX_FEDORA yet: rechunking without --previous-build" ;;
        *) warn "cannot read $APEX_REPO_TESTING:$APEX_FEDORA: rechunking without --previous-build" ;;
    esac

    group "rpm-ostree compose build-chunked-oci"
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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
