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

  ci-build <40 lowercase hex digits> [daily | next | gate | g4]

or `ci-build modes`, which prints the modes this copy takes ("daily next gate g4"): vm.yml asks
before it sends next, which an older copy refuses.

It fetches main from APEX_CI_REMOTE, refuses a commit that main does not contain, checks
the commit out in a clean ~/apex-image (keeping _build/, where the G4 record lives), and
runs, in order: the components hook (tools/components.sh fetch, once the repository has
it), build-image.sh (the RPMs, libfprint, the rebuild lane, the image, G2 twice, G4 when
due, _build/gates-passed.txt), and lane.sh promote when the gates passed. The log goes to
stderr; stdout is a tar of the results: ci-build.txt, gates-passed.txt, g2-result.txt,
g4-results.md and g4-passed.txt when this run wrote them, lock.diff (rpms.lock to
rpms.lock.next before the promotion), qualify-logs/: the screendumps, journals and
serial logs this run's G4 wrote, g2-logs/: each G2 run's assert.txt and its failing
cases' logs, and diag-logs/: what qualify.sh local-diag wrote, each file at most 20 MiB
and 200 MiB in all three (each directory's SKIPPED lists the rest). stages.tsv has the
UTC second each stage began: ci-build's own and every "== " line of build-image.sh's
log, then "end"; build-image.sh's "== plan: " line also goes to ci-build.txt as "plan".
metrics/ holds metrics.sh's metrics.tsv, history.tsv and warnings.tsv (S4's
budget, warning-only). The mode goes to build-image.sh as APEX_CI_MODE: none lets it
choose (a qualify-only run when its conditions hold), daily and gate force the full gate
run, gate with G4 due whatever its last pass, and g4 forces the qualify-only run, which
build-image.sh refuses (exit 2) when its conditions fail; lane.sh promote runs for none,
daily and gate only. For gate and g4, a commit whose build-image.sh predates APEX_CI_MODE
is refused before it builds, and a run whose _build/plan.txt does not name the plan asked
for exits 2 with its gates record removed ("plan refused" in ci-build.txt). With daily (vm.yml's scheduled run), metrics.sh also takes the
image's size, and lane-absorb-report.sh runs after the build, whatever its result:
absorb/ holds its report.md, rows.tsv, logs/ and warnings.tsv, one "family, SRPM,
result, detail" line for each updates-testing row that is not "applies" or "same".
Neither ever changes the exit status.

With next (vm.yml's next-compose, report-only), it builds the commit's next release, the
one image/fedora/N.env with LANE=next, as APEX_FEDORA=N: the components, the lane in
~/apex-store/next, the image and G1, never G2, G4, metrics or a promotion. next/ holds
build.env (BASE_SOURCE, BASE_VERSION), image.env and the next lane's rpms.lock.next;
ci-build.txt names the release, whether the kernel pair was available, and each family
that fell back to Fedora's build ("fallback FAMILY at STEP (LOG): REASON"; next/failures/ holds
those logs). A commit
without a next release builds nothing and says "next none". When this installed copy
differs from the
commit's tools/builder-vm/ci-build.sh, ci-build.txt says "stale"; it never updates
itself from the checkout, which would let any commit of main rewrite the forced command.
Nothing is pushed or signed but the RPMs, and the RPM key and ~/apex-store never leave
the VM.

~/.config/apex/ci.env may set APEX_CI_REMOTE (default
https://github.com/apex-linux/apex-image.git); it is read as data, never sourced.

Exit: the build's status; 2 for a refused request; 75 while another build holds the VM.
EOF
}

readonly CHECKOUT=$HOME/apex-image
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
readonly SELF
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

LOGS_KIB=0

log() { printf 'ci-build: %s\n' "$*" >&2; }
refuse() { log "refused: $*"; exit "$EXIT_REFUSED"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Hooks and fsmonitor of a .git that builder-vm.sh sync copied from the host never run here.
git_() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c safe.directory="$CHECKOUT" -C "$CHECKOUT" "$@"; }

requested_sha() {
    local request=${SSH_ORIGINAL_COMMAND-}
    [[ $request =~ ^ci-build\ ([0-9a-f]{40})(\ (daily|next|gate|g4))?$ ]] || return 1
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
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

check_installed() {
    [[ -f tools/builder-vm/ci-build.sh ]] || return 0
    cmp -s -- "$SELF" tools/builder-vm/ci-build.sh ||
        printf 'stale %s differs from this commit'"'"'s tools/builder-vm/ci-build.sh: run just vm-ci-install\n' "$SELF"
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

# The evidence behind G4's rows, for vm.yml's artifact; this run's files only. Every
# copy into one artifact shares LOGS_KIB, and so the 200 MiB.
copy_qualify_logs() {
    local source=$1 destination=$2 stamp=$3 size path
    [[ -d $source ]] || return 0
    mkdir -p -- "$destination"
    while IFS=' ' read -r size path; do
        size=$(((size + 1023) / 1024))
        if ((size > LOG_MAX_FILE_KIB || LOGS_KIB + size > LOG_MAX_TOTAL_KIB)); then
            printf '%s %s KiB\n' "$path" "$size" >>"$destination/SKIPPED"
            continue
        fi
        LOGS_KIB=$((LOGS_KIB + size))
        mkdir -p -- "$destination/$(dirname -- "$path")"
        cp -- "$source/$path" "$destination/$path"
    done < <(find "$source" -maxdepth "${4:-1}" -type f -newer "$stamp" -printf '%s %P\n' | sort -k2 |
        { if (($# > 4)); then grep -E "^[0-9]+ (${5})$" || true; else cat; fi; })
}

# Each G2 run's assert.txt and the logs of the cases it failed.
copy_g2_logs() {
    local runs=$1 destination=$2 stamp=$3 cases
    [[ -d $runs ]] || return 0
    cases=$({ cat -- "$runs"/run-*/assert.txt 2>/dev/null || true; } | awk '$1 == "FAIL" { sub(/:$/, "", $2); print $2 }' |
        { grep -xE '[A-Za-z0-9_-]+' || true; } | sort -u | paste -sd'|' -)
    copy_qualify_logs "$runs" "$destination" "$stamp" 2 "run-[0-9]+/(assert\.txt${cases:+|(${cases})\.log})"
}

clock() { printf '%(%s)T\t%s\n' -1 "$2" >>"$1"; }

# build-image.sh's log passes through unchanged; each "== " line also starts a stage.
stage_clock() {
    local out=$1 line
    while IFS= read -r line; do
        printf '%s\n' "$line"
        [[ $line == '== '* ]] || continue
        clock "$out/stages.tsv" "${line#== }"
        [[ $line != '== plan: '* ]] || printf 'plan %s\n' "${line#== plan: }" >>"$out/ci-build.txt"
    done
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
    LOGS_KIB=0 copy_qualify_logs _build/absorb/logs "$out/absorb/logs" "$stamp"
    [[ -s $out/absorb/rows.tsv ]] || return 0
    awk -F'\t' '$2 == "testing" && $4 != "applies" && $4 != "same" { print $1 "\t" $3 "\t" $4 "\t" $5 }' \
        "$out/absorb/rows.tsv" >"$out/absorb/warnings.tsv"
}

# The one image/fedora/N.env with LANE=next, as N; none is no error, two are.
next_release() {
    local env release found=
    for env in image/fedora/*.env; do
        grep -qx 'LANE=next' "$env" 2>/dev/null || continue
        release=$(sed -n 's/^FEDORA=//p' "$env" | head -n 1)
        if [[ -n $found || ! $release =~ ^[0-9]{2}$ || $env != "image/fedora/$release.env" ]]; then
            log "next: $env is not the one next release (FEDORA=$release, after '${found:-none}')"
            return 1
        fi
        found=$release
    done
    printf '%s\n' "${found:-none}"
}

# Whether the next image took the kernel pair, from the next lane's lock.
pair_state() {
    local line reason
    line=$(awk '$1 == "family" && $2 == "kernel-cachyos"' "$1" 2>/dev/null)
    case $(awk '{ print $3 }' <<<"$line") in
        '') echo "pair none: no kernel-cachyos family in the next lane's lock" ;;
        stock)
            reason=${line#*reason=}
            [[ $reason == "pair unavailable"* ]] || reason="pair stock: $reason"
            echo "$reason" ;;
        *) echo "pair available: $(awk '{ print $3, $4 }' <<<"$line")" ;;
    esac
}

# The families that fell back to Fedora's build on the next release: the port's to-do list.
fallbacks() {
    awk '$1 == "family" && $3 == "stock" && / reason=next lane fallback / {
        f = $2; sub(/^.* reason=next lane fallback /, ""); print "fallback " f " " $0 }' "$1" 2>/dev/null || true
}

copy_failures() {
    local store=$1 destination=$2 stamp=$3 log name
    for log in "$store"/*/last-failure.txt; do
        [[ -s $log && $log -nt $stamp ]] || continue
        name=${log%/last-failure.txt}
        mkdir -p -- "$destination"
        cp -- "$log" "$destination/${name##*/}.txt"
    done
}

build_next() {
    local sha=$1 out=$2 rc=0 release
    fetch_main
    check_out "$sha"
    cd -- "$CHECKOUT"
    check_installed >>"$out/ci-build.txt"
    release=$(next_release) || return 1
    printf 'next %s\n' "$release" >>"$out/ci-build.txt"
    [[ $release != none ]] || { log "next: this commit has no image/fedora/*.env with LANE=next"; return 0; }
    export APEX_FEDORA=$release
    stage_components 9>&- </dev/null >&2
    log "== build-image.sh, the next lane (Fedora $release): components, lane, image, G1"
    bash tools/builder-vm/build-image.sh 9>&- </dev/null >&2 || rc=$?
    printf 'build-image %s\n' "$rc" >>"$out/ci-build.txt"
    mkdir -p -- "$out/next"
    copy_if_newer _build/next/image/build.env "$out/next/build.env" "$out/.started"
    copy_if_newer _build/next/image/image.env "$out/next/image.env" "$out/.started"
    copy_if_newer "$STORE/next/rpms.lock.next" "$out/next/rpms.lock.next" "$out/.started"
    pair_state "$out/next/rpms.lock.next" >>"$out/ci-build.txt"
    fallbacks "$out/next/rpms.lock.next" >>"$out/ci-build.txt"
    copy_failures "$STORE/next/pkgs" "$out/next/failures" "$out/.started"
    return "$rc"
}

plan_of() { if [[ -s _build/plan.txt && _build/plan.txt -nt $1 ]]; then cat -- _build/plan.txt; else echo nothing; fi; }

# MODE STAMP: gate and g4 ask build-image.sh for one plan; this run's plan.txt must name it.
plan_honoured() {
    case $1 in
        gate) [[ $(plan_of "$2") == gate ]] ;;
        g4) [[ $(plan_of "$2") == qualify-only ]] ;;
        *) return 0 ;;
    esac
}

build() {
    local sha=$1 out=$2 mode=$3 rc=0 promote daily=
    [[ $mode != daily ]] || daily=daily
    local stamp=$out/.started
    : >"$stamp"
    clock "$out/stages.tsv" "fetch and check out"
    fetch_main
    check_out "$sha"
    cd -- "$CHECKOUT"
    check_installed >>"$out/ci-build.txt"
    clock "$out/stages.tsv" "components (ci-build)"
    stage_components 9>&- </dev/null >&2
    if [[ $mode == gate || $mode == g4 ]] && ! grep -q 'APEX_CI_MODE' tools/builder-vm/build-image.sh; then
        printf 'plan refused: %s predates APEX_CI_MODE, so it cannot run %s\n' "$sha" "$mode" >>"$out/ci-build.txt"
        log "refused: this commit's build-image.sh predates APEX_CI_MODE; it would not run $mode"
        return "$EXIT_REFUSED"
    fi
    log "== build-image.sh: RPMs, libfprint, lane, image, G4 when due, G2 twice, gates record"
    APEX_CI_MODE=$mode bash tools/builder-vm/build-image.sh 9>&- </dev/null 2>&1 | stage_clock "$out" >&2 || rc=$?
    printf 'build-image %s\n' "$rc" >>"$out/ci-build.txt"
    if ! plan_honoured "$mode" "$stamp"; then
        rm -f -- _build/gates-passed.txt
        printf 'plan refused: build-image.sh ran %s, not %s; no gates record\n' "$(plan_of "$stamp")" "$mode" >>"$out/ci-build.txt"
        log "refused: build-image.sh did not run the $mode plan; its gates record is removed"
        rc=$EXIT_REFUSED
    fi
    clock "$out/stages.tsv" "results, metrics and promotion (ci-build)"
    lock_diff >"$out/lock.diff" 2>&1 || true
    copy_if_newer _build/gates-passed.txt "$out/gates-passed.txt" "$stamp"
    copy_if_newer _build/g2/latest/result.txt "$out/g2-result.txt" "$stamp"
    copy_if_newer _build/qualify/results.md "$out/g4-results.md" "$stamp"
    copy_if_newer _build/g4-passed.txt "$out/g4-passed.txt" "$stamp"
    copy_qualify_logs _build/qualify/logs "$out/qualify-logs" "$stamp"
    copy_g2_logs _build/g2/latest "$out/g2-logs" "$stamp"
    copy_qualify_logs _build/qualify/diag "$out/diag-logs" "$stamp" 2
    if [[ -f tools/builder-vm/metrics.sh ]]; then
        bash tools/builder-vm/metrics.sh "$out/metrics" "$stamp" "$sha" "$out/lock.diff" ${daily:+size} 9>&- </dev/null >&2 ||
            log "metrics: exit $?; they never gate"
    fi
    [[ -z $daily ]] || stage_absorb "$out" "$stamp" || true
    ((rc == 0)) || return "$rc"
    if [[ $mode == g4 ]]; then
        printf 'promote skipped: g4 is qualify-only\n' >>"$out/ci-build.txt"
        return 0
    fi
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
    local sha mode out rc request
    if [[ ${SSH_ORIGINAL_COMMAND-} == "ci-build modes" ]]; then
        echo "daily next gate g4"
        exit 0
    fi
    request=$(requested_sha) || refuse "the command must be exactly 'ci-build <40-hex sha> [daily | next | gate | g4]'"
    read -r sha mode <<<"$request"

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
    if [[ $mode == next ]]; then
        (set -e; : >"$out/.started"; build_next "$sha" "$out")
    else
        (set -e; build "$sha" "$out" "$mode")
    fi
    rc=$?
    set -e
    clock "$out/stages.tsv" end
    printf 'finished %s\nexit %s\n' "$(utc_now)" "$rc" >>"$out/ci-build.txt"
    rm -f -- "$out/.started"
    tar -C "$out" -cf - . >&3
    exit "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
