#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: components.sh fetch | env | promotable | provenance

The component checkouts the image builds from, pinned by components.lock at the root of
this checkout: one line per repository, `NAME GIT-URL SHA` (40 lowercase hex digits);
blank lines and lines starting with # are skipped.

  fetch       clone each component into _build/components/NAME with its full history
              (the lane counts commits), check out SHA, and require HEAD == SHA, a clean
              tree and a clone that is not shallow; record the result in
              _build/components/state.txt
  env         print, as shell assignments, APEX_SYSTEM_SRC (apex-system),
              APEX_DESKTOP_SRC (apex-desktop), APEX_GNOME_SRC (apex-gnome),
              APEX_KERNEL_SRC (the component holding packaging/libfprint, default this
              checkout), APEX_LANE_RECIPES (this checkout and every component with
              packaging/pkgs, ':'-separated) and APEX_COMPONENTS (pinned, or
              dev-override); refuses a state older than components.lock
  promotable  exit 0 when the last fetch used only pinned clones (or there is no
              components.lock), 1 otherwise
  provenance  exit 0 when every pin of the last pinned fetch is on its component's main,
              or on a pin/* branch whose commits past main are each a `git cherry-pick -x`
              of a commit X on main, with a `(cherry picked from commit X)` trailer and
              changing only paths that X changes; 1 otherwise

APEX_SRC_<NAME> (NAME upper-cased, - as _; APEX_SRC_APEX_DESKTOP for apex-desktop)
points at a sibling checkout to use instead of the pinned clone, relative to this
checkout. The state then records dev-override, and lane.sh promote refuses such a build.
Without components.lock this checkout holds every component, and fetch records none.
EOF
}

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly LOCK=$ROOT/components.lock
readonly DIR=$ROOT/_build/components
readonly STATE=$DIR/state.txt
readonly EXIT_USAGE=2

log() { printf 'components: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
bad_lock() { log "error: components.lock:$1: $2"; exit "$EXIT_USAGE"; }

# Hooks and fsmonitor of a component repository never run here.
git_in() {
    local dir=$1
    shift
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c safe.directory="$dir" -C "$dir" "$@"
}

lock_sha256() {
    if [[ -f $LOCK ]]; then sha256sum <"$LOCK" | cut -d' ' -f1; else echo none; fi
}

override_var() {
    local name=${1^^}
    printf 'APEX_SRC_%s\n' "${name//-/_}"
}

# Prints `NAME URL SHA` per component, or exits 2 at the first malformed line.
read_lock() {
    [[ -f $LOCK ]] || return 0
    local line n=0 name url sha extra
    local -A seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        read -r name url sha extra <<<"$line"
        [[ -n $sha && -z $extra ]] || bad_lock "$n" "expected NAME GIT-URL SHA"
        [[ $name =~ ^[a-z][a-z0-9-]*$ ]] || bad_lock "$n" "the name '$name' is not [a-z][a-z0-9-]*"
        [[ $url != -* ]] || bad_lock "$n" "the URL of $name starts with -"
        [[ $sha =~ ^[0-9a-f]{40}$ ]] || bad_lock "$n" "the commit of $name is not 40 lowercase hex digits"
        [[ -z ${seen[$name]:-} ]] || bad_lock "$n" "$name is listed twice"
        seen[$name]=1
        printf '%s %s %s\n' "$name" "$url" "$sha"
    done <"$LOCK"
}

# A build killed between its root container and the chown back leaves root's files in the
# checkout (build-image.sh in_component), which neither clean nor rm can then remove.
reclaim() {
    local name=$1 dest=$2
    [[ -e $dest && -n $(find "$dest" ! -user "$(id -u)" -print -quit) ]] || return 0
    log "$name: taking back the files another user left in $dest"
    sudo -n chown -R "$(id -u):$(id -g)" -- "$dest" ||
        die "$name: $dest holds another user's files, and sudo -n cannot take them back"
}

clone_pinned() {
    local name=$1 url=$2 sha=$3 dest=$DIR/$1
    reclaim "$name" "$dest"
    if [[ -d $dest/.git && $(git_in "$dest" remote get-url origin 2>/dev/null) == "$url" ]]; then
        git_in "$dest" fetch -q --no-tags --prune origin '+refs/heads/*:refs/remotes/origin/*'
    else
        rm -rf -- "$dest"
        git -c core.hooksPath=/dev/null clone -q --no-checkout --no-tags -- "$url" "$dest"
    fi
    if [[ $(git_in "$dest" rev-parse --is-shallow-repository) == true ]]; then
        git_in "$dest" fetch -q --no-tags --unshallow origin
    fi
    git_in "$dest" cat-file -e "$sha^{commit}" 2>/dev/null || git_in "$dest" fetch -q --no-tags origin "$sha" ||
        die "$name: $url has no commit $sha"
    git_in "$dest" checkout -q --force --detach "$sha"
    git_in "$dest" clean -q -ffdx
    [[ $(git_in "$dest" rev-parse HEAD) == "$sha" ]] || die "$name: HEAD is not $sha"
    [[ $(git_in "$dest" rev-parse --is-shallow-repository) == false ]] || die "$name: the clone is shallow"
    [[ -z $(git_in "$dest" status --porcelain) ]] || die "$name: the checkout of $sha is not clean"
}

cmd_fetch() {
    local components name url sha var path head state
    components=$(read_lock)
    mkdir -p -- "$DIR"
    state=$(mktemp "$DIR/.state.XXXXXX")
    # shellcheck disable=SC2064 # expand now: the path is local
    trap "rm -f -- '$state'" EXIT
    printf 'lock-sha256 %s\n' "$(lock_sha256)" >"$state"
    while read -r name url sha; do
        [[ -n $name ]] || continue
        var=$(override_var "$name")
        if [[ -n ${!var:-} ]]; then
            path=$(cd -- "$ROOT" && cd -- "${!var}" 2>/dev/null && pwd) || die "$name: $var=${!var} is not a directory"
            head=$(git_in "$path" rev-parse -q --verify HEAD) || die "$name: $var=${!var} is not a git checkout"
            log "$name: dev-override, $path at $head instead of $sha; such a build never promotes"
            printf 'component %s dev-override %s %s\n' "$name" "$head" "$path" >>"$state"
        else
            clone_pinned "$name" "$url" "$sha"
            log "$name: $sha"
            printf 'component %s pinned %s %s\n' "$name" "$sha" "$DIR/$name" >>"$state"
        fi
    done <<<"$components"
    [[ -n $components ]] || log "no components.lock: this checkout holds every component"
    mv -f -- "$state" "$STATE"
    trap - EXIT
}

current_state() {
    [[ -s $STATE ]] || die "no $STATE: run components.sh fetch"
    [[ $(sed -n 's/^lock-sha256 //p' "$STATE") == "$(lock_sha256)" ]] ||
        die "components.lock changed since the last fetch: run components.sh fetch"
}

cmd_env() {
    current_state
    local kind name mode sha path recipes=$ROOT overall=pinned kernel=$ROOT kernel_name=
    while read -r kind name mode sha path; do
        [[ $kind == component ]] || continue
        [[ $mode == pinned ]] || overall=dev-override
        case $name in
            apex-system) printf 'export APEX_SYSTEM_SRC=%q\n' "$path" ;;
            apex-desktop) printf 'export APEX_DESKTOP_SRC=%q\n' "$path" ;;
            apex-gnome) printf 'export APEX_GNOME_SRC=%q\n' "$path" ;;
        esac
        [[ ! -d $path/packaging/pkgs ]] || recipes+=:$path
        if [[ -d $path/packaging/libfprint ]]; then
            [[ -z $kernel_name ]] || die "both $kernel_name and $name hold packaging/libfprint"
            kernel=$path kernel_name=$name
        fi
    done <"$STATE"
    printf 'export APEX_KERNEL_SRC=%q\n' "$kernel"
    printf 'export APEX_LANE_RECIPES=%q\n' "$recipes"
    printf 'export APEX_COMPONENTS=%q\n' "$overall"
}

cmd_promotable() {
    [[ -f $LOCK ]] || return 0
    current_state
    if grep -q '^component [^ ]* dev-override ' "$STATE"; then
        log "the last fetch used a dev-override: $(awk '$3 == "dev-override" {print $2}' "$STATE" | paste -sd' ' -)"
        return 1
    fi
}

# Why commit C of REPO is no cherry-pick of a commit on MAIN that changes the same paths.
not_a_pick() {
    local repo=$1 c=$2 main=$3 x extra
    (($(git_in "$repo" rev-list --no-walk --count --min-parents=2 "$c") == 0)) || { echo "is a merge"; return; }
    x=$(git_in "$repo" log -1 --format=%B "$c" | sed -n 's/^(cherry picked from commit \([0-9a-f]\{40\}\))$/\1/p' | tail -n 1)
    [[ -n $x ]] || { echo "has no (cherry picked from commit X) trailer"; return; }
    git_in "$repo" merge-base --is-ancestor "$x" "$main" 2>/dev/null || { echo "names ${x:0:12}, which is not on main"; return; }
    extra=$(comm -23 <(git_in "$repo" diff --name-only "$c^" "$c" | LC_ALL=C sort) \
        <(git_in "$repo" diff --name-only "$x^" "$x" | LC_ALL=C sort) | paste -sd' ' -)
    [[ -z $extra ]] || echo "changes paths that ${x:0:12} does not: $extra"
}

cmd_provenance() {
    cmd_promotable || die "provenance checks the pinned clones: run components.sh fetch without APEX_SRC_*"
    local name url sha repo main=refs/remotes/origin/main c why bad=0 picked
    while read -r name url sha; do
        repo=$DIR/$name
        if git_in "$repo" merge-base --is-ancestor "$sha" "$main" 2>/dev/null; then
            log "$name: ${sha:0:12} is on main"
            continue
        fi
        if ! git_in "$repo" for-each-ref --contains "$sha" --format='%(refname)' refs/remotes/origin/pin | grep -q .; then
            log "error: $name: ${sha:0:12} is neither on main nor on a pin/* branch"
            bad=1
            continue
        fi
        picked=1
        for c in $(git_in "$repo" rev-list --reverse "$main..$sha"); do
            why=$(not_a_pick "$repo" "$c" "$main")
            [[ -z $why ]] || { log "error: $name: ${c:0:12}, on the way from main to the pin ${sha:0:12}, $why"; picked=0 bad=1; }
        done
        ((picked == 0)) || log "$name: ${sha:0:12} is on a pin/* branch, cherry-picked from main"
    done < <(read_lock)
    return "$bad"
}

main() {
    (($# == 1)) || { usage >&2; exit "$EXIT_USAGE"; }
    case $1 in
        fetch) cmd_fetch ;;
        env) cmd_env ;;
        promotable) cmd_promotable ;;
        provenance) cmd_provenance ;;
        -h | --help | help) usage ;;
        *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
}

main "$@"
