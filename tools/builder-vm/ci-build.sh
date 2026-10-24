#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: ci-build                (the forced command of the CI key, as the builder user)

The builder VM's one entry point for the self-hosted runner (tools/runner/README.md).
`builder-vm.sh ci-install` installs it outside the checkout, at
/usr/local/libexec/apex/ci-build, and binds the runner's key to it in authorized_keys
with restrict,command=. It takes nothing but SSH_ORIGINAL_COMMAND, which must be exactly

  ci-build <40 lowercase hex digits> [daily]

It fetches main from APEX_CI_REMOTE, refuses a commit that main does not contain, checks
the commit out in a clean ~/apex-image (keeping _build/, where the G4 record lives), and
runs, in order: the components hook (tools/components.sh fetch, once the repository has
it), build-image.sh (the RPMs, libfprint, the rebuild lane, the image, G2 twice, G4 when
due, _build/gates-passed.txt), and lane.sh promote when the gates passed. The log goes to
stderr; stdout is a tar of the results: ci-build.txt, gates-passed.txt, g2-result.txt,
g4-results.md and g4-passed.txt when this run wrote them, lock.diff (rpms.lock to
rpms.lock.next before the promotion), and qualify-logs/: the screendumps, journals and
serial logs this run's G4 wrote, each at most 20 MiB and 200 MiB in all (SKIPPED lists
the rest). metrics/ holds metrics.sh's metrics.tsv, history.tsv and warnings.tsv (S4's
budget, warning-only). With daily (vm.yml's scheduled run), metrics.sh also takes the
image's size, and lane-absorb-report.sh runs after the build, whatever its result:
absorb/ holds its report.md, rows.tsv, logs/ and warnings.tsv, one "family, SRPM,
result, detail" line for each updates-testing row that is not "applies" or "same".
Neither ever changes the exit status.
Nothing is pushed or signed but the RPMs, and the RPM key and ~/apex-store never leave
the VM.

~/.config/apex/ci.env may set APEX_CI_REMOTE (default
https://github.com/apex-linux/apex-image.git); it is read as data, never sourced.

Exit: the build's status; 2 for a refused request; 75 while another build holds the VM.
EOF
}

readonly CHECKOUT=$HOME/apex-image
readonly STORE=${APEX_STORE:-$HOME/apex-store}
readonly CI_ENV=$HOME/.config/apex/ci.env
readonly BUILD_LOCK=$HOME/.apex-build.lock
readonly DEFAULT_REMOTE=https://github.com/apex-linux/apex-image.git
readonly MAIN_REF=refs/remotes/origin/main
readonly LOCK_WAIT_SECONDS=1800
readonly EXIT_REFUSED=2
readonly EXIT_BUSY=75
readonly LOG_MAX_FILE_KIB=20480
readonly LOG_MAX_TOTAL_KIB=204800

log() { printf 'ci-build: %s\n' "$*" >&2; }
refuse() { log "refused: $*"; exit "$EXIT_REFUSED"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Hooks and fsmonitor of a .git that builder-vm.sh sync copied from the host never run here.
git_() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c safe.directory="$CHECKOUT" -C "$CHECKOUT" "$@"; }

requested_sha() {
    local request=${SSH_ORIGINAL_COMMAND-}
    [[ $request =~ ^ci-build\ ([0-9a-f]{40})(\ daily)?$ ]] || return 1
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]:+daily}"
}

ci_remote() {
    local remote
    remote=$(sed -n 's/^APEX_CI_REMOTE=//p' "$CI_ENV" 2>/dev/null | tail -n 1)
    printf '%s\n' "${remote:-$DEFAULT_REMOTE}"
}

fetch_main() {
    local remote
    remote=$(ci_remote)
    if [[ ! -e $CHECKOUT/.git ]] || ! git_ rev-parse --git-dir >/dev/null 2>&1; then
        rm -rf -- "$CHECKOUT/.git"
        mkdir -p -- "$CHECKOUT"
        git_ init -q
    fi
    log "fetching main from $remote"
    git_ fetch -q --no-tags --force "$remote" "+refs/heads/main:$MAIN_REF"
    # apex-lane counts history for its release numbers and refuses a shallow clone.
    if [[ $(git_ rev-parse --is-shallow-repository) == true ]]; then
        git_ fetch -q --no-tags --unshallow "$remote" "+refs/heads/main:$MAIN_REF"
    fi
}

check_out() {
    local sha=$1
    git_ cat-file -e "$sha^{commit}" 2>/dev/null || refuse "$sha is not a commit of $(ci_remote)"
    git_ merge-base --is-ancestor "$sha" "$MAIN_REF" || refuse "$sha is not reachable from origin/main"
    git_ checkout -q --force --detach "$sha"
    git_ clean -q -ffdx -e /_build/
    [[ $(git_ rev-parse HEAD) == "$sha" && -z $(git_ status --porcelain) ]] ||
        { log "the checkout of $sha is not clean"; return 1; }
    log "checked out $sha in $CHECKOUT"
}

stage_components() {
    log "== components"
    # Hook for the split: tools/components.sh fetch brings the component builds the image takes.
    if [[ -x tools/components.sh ]]; then
        tools/components.sh fetch
    else
        log "components: this commit has no tools/components.sh; the checkout builds them"
    fi
}

lock_diff() {
    if [[ ! -s $STORE/rpms.lock.next ]]; then
        echo "no $STORE/rpms.lock.next"
    elif [[ ! -s $STORE/rpms.lock ]]; then
        echo "no $STORE/rpms.lock yet; rpms.lock.next:"
        cat -- "$STORE/rpms.lock.next"
    else
        diff -u --label rpms.lock --label rpms.lock.next -- "$STORE/rpms.lock" "$STORE/rpms.lock.next" ||
            [[ $? == 1 ]]
    fi
}

stage_promote() {
    if [[ ! -s _build/gates-passed.txt ]]; then
        echo "skipped: no gates record"
    elif cmp -s -- "$STORE/rpms.lock" "$STORE/rpms.lock.next"; then
        echo "unchanged: rpms.lock is rpms.lock.next"
    elif tools/builder-vm/lane.sh promote 9>&- </dev/null >&2; then
        echo passed
    else
        echo failed
        return 1
    fi
}

copy_if_newer() {
    local source=$1 destination=$2 stamp=$3
    if [[ -s $source && $source -nt $stamp ]]; then cp -- "$source" "$destination"; fi
}

# The evidence behind G4's rows, for vm.yml's artifact; this run's files only.
copy_qualify_logs() {
    local source=$1 destination=$2 stamp=$3 total=0 size path
    [[ -d $source ]] || return 0
    mkdir -p -- "$destination"
    while IFS=' ' read -r size path; do
        size=$(((size + 1023) / 1024))
        if ((size > LOG_MAX_FILE_KIB || total + size > LOG_MAX_TOTAL_KIB)); then
            printf '%s %s KiB\n' "$path" "$size" >>"$destination/SKIPPED"
            continue
        fi
        total=$((total + size))
        cp -- "$source/$path" "$destination/$path"
    done < <(find "$source" -maxdepth 1 -type f -newer "$stamp" -printf '%s %f\n' | sort -k2)
}

# The early warning of S1b's absorption; it never gates.
stage_absorb() {
    local out=$1 stamp=$2 rc=0
    log "== lane-absorb-report.sh"
    bash tools/builder-vm/lane-absorb-report.sh 9>&- </dev/null >&2 || rc=$?
    printf 'absorb %s\n' "$rc" >>"$out/ci-build.txt"
    mkdir -p -- "$out/absorb"
    copy_if_newer _build/absorb/report.md "$out/absorb/report.md" "$stamp"
    copy_if_newer _build/absorb/rows.tsv "$out/absorb/rows.tsv" "$stamp"
    copy_qualify_logs _build/absorb/logs "$out/absorb/logs" "$stamp"
    [[ -s $out/absorb/rows.tsv ]] || return 0
    awk -F'\t' '$2 == "testing" && $4 != "applies" && $4 != "same" { print $1 "\t" $3 "\t" $4 "\t" $5 }' \
        "$out/absorb/rows.tsv" >"$out/absorb/warnings.tsv"
}

build() {
    local sha=$1 out=$2 daily=$3 rc=0 promote
    local stamp=$out/.started
    : >"$stamp"
    fetch_main
    check_out "$sha"
    cd -- "$CHECKOUT"
    stage_components 9>&- </dev/null >&2
    log "== build-image.sh: RPMs, libfprint, lane, image, G2 twice, G4 when due, gates record"
    bash tools/builder-vm/build-image.sh 9>&- </dev/null >&2 || rc=$?
    printf 'build-image %s\n' "$rc" >>"$out/ci-build.txt"
    lock_diff >"$out/lock.diff" 2>&1 || true
    copy_if_newer _build/gates-passed.txt "$out/gates-passed.txt" "$stamp"
    copy_if_newer _build/g2/latest/result.txt "$out/g2-result.txt" "$stamp"
    copy_if_newer _build/qualify/results.md "$out/g4-results.md" "$stamp"
    copy_if_newer _build/g4-passed.txt "$out/g4-passed.txt" "$stamp"
    copy_qualify_logs _build/qualify/logs "$out/qualify-logs" "$stamp"
    if [[ -f tools/builder-vm/metrics.sh ]]; then
        bash tools/builder-vm/metrics.sh "$out/metrics" "$stamp" "$sha" "$out/lock.diff" ${daily:+size} 9>&- </dev/null >&2 ||
            log "metrics: exit $?; they never gate"
    fi
    [[ -z $daily ]] || stage_absorb "$out" "$stamp" || true
    ((rc == 0)) || return "$rc"
    log "== promote the lane lock"
    promote=$(stage_promote) || rc=$?
    printf 'promote %s\n' "$promote" >>"$out/ci-build.txt"
    return "$rc"
}

main() {
    case ${1:-} in
        -h | --help) usage; exit 0 ;;
        '') ;;
        *) usage >&2; exit "$EXIT_REFUSED" ;;
    esac
    local sha daily out rc request
    request=$(requested_sha) || refuse "the command must be exactly 'ci-build <40-hex sha> [daily]'"
    read -r sha daily <<<"$request"

    # stdout carries only the results tar.
    exec 3>&1 1>&2
    exec 9>"$BUILD_LOCK"
    flock -w "$LOCK_WAIT_SECONDS" 9 || { log "another build holds the builder VM ($BUILD_LOCK)"; exit "$EXIT_BUSY"; }

    out=$(mktemp -d)
    # shellcheck disable=SC2064 # expand now: the path is local
    trap "rm -rf -- '$out'" EXIT
    printf 'sha %s\nstarted %s\n' "$sha" "$(utc_now)" >"$out/ci-build.txt"
    # Not under ||, which would switch errexit off inside the build.
    set +e
    (set -e; build "$sha" "$out" "$daily")
    rc=$?
    set -e
    printf 'finished %s\nexit %s\n' "$(utc_now)" "$rc" >>"$out/ci-build.txt"
    rm -f -- "$out/.started"
    tar -C "$out" -cf - . >&3
    exit "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
