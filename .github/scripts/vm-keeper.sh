#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: vm-keeper.sh run              (vm-keeper.yml, hourly)
       vm-keeper.sh decide RUNS.json (the decision alone, on a fixture)

Re-dispatches vm.yml on main's head after a run that gave no verdict, and keeps the
"VM status" issue. Off unless the repository variable APEX_VM_KEEPER is "on"
(APEX_VM_KEEPER in the environment), which is checked before anything else.

A run gives no verdict when the build job was cancelled or timed out (a lost runner,
24 hours in the queue) or its gates step says "the builder VM returned no results"
(ssh exit 255 before the tar, or ci-build's exit 75). A run that failed in the RPMs,
the lane, podman or G1 and returned its results is a verdict; a qualify-only run is
advisory, never a gate verdict, and is not replayed (the daily run is a gate run).
Nothing is dispatched while a vm.yml run is queued for the runner or pending behind
the vm concurrency group, when main's head already has a verdict, when no vm.yml push
path changed since the last verdict, more than once in 3 hours for one commit, or more
than 4 times a day. It reads only the Actions API: the runs, their jobs and the build
job's annotations, which outlive the 14-day artifacts.

RUNS.json for decide: {"now": EPOCH, "main_head": SHA, "changed_since_verdict": BOOL,
"runs": [{id, event, head_sha, status, conclusion, created_at, actor, build:
{status, conclusion}, annotations: [MESSAGE...]}...]}, newest first. It prints one line:
dispatch SHA, wait REASON or none REASON.
EOF
}

readonly REPO=${GITHUB_REPOSITORY:-apex-linux/apex-image}
readonly BOT='github-actions[bot]' SHA_GAP_SECONDS=$((3 * 3600)) DAY_SECONDS=86400 DAY_MAX=4
readonly ISSUE_TITLE="VM status" LAG_KEEP=168 KEEPER_MINUTE=41
readonly BUILD_JOB='builder VM build and gates'
# shellcheck disable=SC2016 # jq's own variables
readonly JQ_KIND='def kind:
    if (.status | IN("queued", "in_progress", "waiting", "requested", "pending")) then "in-flight"
    elif .build == null or .build.conclusion == "skipped" then "skipped"
    elif any(.annotations[]; test("qualify-only")) then "advisory"
    elif (.build.conclusion | IN("cancelled", "timed_out"))
        or any(.annotations[]; test("returned no results|was not acquired by Runner")) then "no-verdict"
    else "verdict" end;'

decide() {
    jq -r --arg bot "$BOT" --argjson gap "$SHA_GAP_SECONDS" --argjson day "$DAY_SECONDS" --argjson max "$DAY_MAX" "$JQ_KIND"'
        def t: fromdateiso8601;
        . as $c
        | [.runs[] | . + {kind: kind}] as $runs
        | ($runs | map(select(.kind == "in-flight"))) as $flight
        | ($runs | map(select(.kind != "skipped")) | first) as $newest
        | ($runs | map(select(.event == "workflow_dispatch" and .actor == $bot))) as $mine
        | if ($flight | length) > 0 then
            "wait run \($flight[0].id) is \($flight[0].status)\(if $flight[0].build.status == "queued" then " for a runner" else "" end)"
          elif $newest == null then "none no vm.yml run yet"
          elif $newest.kind != "no-verdict" then "none run \($newest.id) is \(if $newest.kind == "verdict" then "a verdict" else $newest.kind end)"
          elif any($runs[]; .kind == "verdict" and .head_sha == $c.main_head) then "none main head \($c.main_head[0:12]) has a verdict"
          elif ($c.changed_since_verdict | not) then "none no vm.yml push path changed since the last verdict"
          elif any($mine[]; .head_sha == $c.main_head and ($c.now - (.created_at | t)) < $gap) then
            "wait already dispatched \($c.main_head[0:12]) in the last 3 hours"
          elif ($mine | map(select(($c.now - (.created_at | t)) < $day)) | length) >= $max then
            "wait \($max) dispatches in the last 24 hours"
          else "dispatch \($c.main_head)" end' "$1"
}

api() { gh api -H 'Accept: application/vnd.github+json' "$@"; }

# vm.yml's push paths as one extended regular expression.
paths_regex() {
    awk '/^    paths:$/ { p = 1; next } p && /^      - / { print $2; next } p { exit }' .github/workflows/vm.yml |
        sed -e 's/[.+]/\\&/g' -e 's/\*\*/\x01/g' -e 's/\*/[^\/]*/g' -e 's/\x01/.*/g' -e 's/.*/^&$/' | paste -sd'|' -
}

# The runs of main, newest first, each with its build job and that job's annotations.
gather() {
    local runs id job
    runs=$(api "repos/$REPO/actions/workflows/vm.yml/runs?branch=main&per_page=30" --jq '[.workflow_runs[] |
        {id, event, head_sha, status, conclusion, created_at, actor: .triggering_actor.login}]')
    for id in $(jq -r '.[:12][].id' <<<"$runs"); do
        job=$(api "repos/$REPO/actions/runs/$id/jobs" --jq "[.jobs[] | select(.name == \"$BUILD_JOB\") |
            {id, status, conclusion, started_at}] | first")
        if [[ $job != null ]]; then
            job=$(jq -c --argjson a "$(api "repos/$REPO/check-runs/$(jq -r .id <<<"$job")/annotations" \
                --jq '[.[] | "\(.title // ""): \(.message)"]')" \
                '. + {annotations: $a}' <<<"$job")
        fi
        runs=$(jq -c --argjson id "$id" --argjson job "$job" \
            'map(if .id == $id then . + {build: $job, annotations: ($job.annotations // [])} else . end)' <<<"$runs")
    done
    jq -c 'map(. + {annotations: (.annotations // [])})' <<<"$runs"
}

changed_since() { # SHA HEAD: does a vm.yml push path differ between them
    local re
    re=$(paths_regex)
    api "repos/$REPO/compare/$1...$2" --jq '.files[].filename' | grep -qE "$re"
}

status_body() { # RUNS DECISION LAGS
    local runs=$1 decision=$2 lags=$3
    printf '%s\n\n' "Kept by vm-keeper.yml, hourly. Last tick: $(date -u +%FT%TZ), decision: \`$decision\`."
    printf '| Run | Commit | Event | Result | Annotations |\n|---|---|---|---|---|\n'
    jq -r '.[:10][] | "| \(.id) | \(.head_sha[0:12]) | \(.event) | \(.status)/\(.conclusion // "-") | \(
        [.annotations[] | select(test("G4 frontier|qualify-only|no results|ci-build|failed"))] | join("; ") | gsub("\\|"; "/") | .[0:200]) |"' \
        <<<"$runs"
    jq -r 'map(select(.build.status == "queued")) | last |
        if . == null then "" else "\nRunner offline since \(.created_at): run \(.id) has waited for it." end' <<<"$runs"
    printf '\nCron lag of the last %s ticks (s): %s\n<!-- keeper-lags: %s -->\n' "$(wc -w <<<"$lags")" \
        "$(tr ' ' '\n' <<<"$lags" | sort -n | awk '{ a[NR] = $1 } END { if (NR) printf "median %s, max %s", a[int((NR + 1) / 2)], a[NR] }')" "$lags"
}

cmd_run() {
    [[ ${APEX_VM_KEEPER:-} == on ]] || { echo "vm-keeper: off (repository variable APEX_VM_KEEPER is not on)"; return 0; }
    local runs head verdict changed=true decision ctx issue lags lag
    runs=$(gather)
    head=$(api "repos/$REPO/commits/main" --jq .sha)
    verdict=$(jq -r "$JQ_KIND"'[.[] | select(kind == "verdict")][0].head_sha // empty' <<<"$runs")
    if [[ -n $verdict ]] && ! changed_since "$verdict" "$head"; then changed=false; fi
    ctx=$(mktemp)
    jq -n --argjson runs "$runs" --arg head "$head" --argjson changed "$changed" --argjson now "$(date +%s)" \
        '{now: $now, main_head: $head, changed_since_verdict: $changed, runs: $runs}' >"$ctx"
    decision=$(decide "$ctx")
    rm -f -- "$ctx"
    echo "vm-keeper: $decision"
    if [[ $decision == dispatch\ * ]]; then
        gh workflow run vm.yml --repo "$REPO" --ref main
    fi
    issue=$(api "repos/$REPO/issues?state=open&per_page=100" --jq "[.[] | select(.title == \"$ISSUE_TITLE\" and .pull_request == null)][0].number // empty")
    lags=
    [[ -z $issue ]] || lags=$(api "repos/$REPO/issues/$issue" --jq .body | sed -n 's/^<!-- keeper-lags: \(.*\) -->$/\1/p')
    # Seconds past the cron's minute: how late GitHub starts a scheduled tick.
    if [[ ${GITHUB_EVENT_NAME:-} == schedule ]]; then
        lag=$(($(date +%s) % 3600 - KEEPER_MINUTE * 60))
        lags=$(echo "$lags $lag" | tr ' ' '\n' | sed '/^$/d' | tail -n "$LAG_KEEP" | paste -sd' ' -)
    fi
    if [[ -z $issue ]]; then
        gh issue create --repo "$REPO" --title "$ISSUE_TITLE" --body "$(status_body "$runs" "$decision" "$lags")" >/dev/null
    else
        gh issue edit "$issue" --repo "$REPO" --body "$(status_body "$runs" "$decision" "$lags")" >/dev/null
    fi
}

main() {
    case ${1:-} in
        run) cmd_run ;;
        decide) (($# == 2)) || { usage >&2; exit 2; }; decide "$2" ;;
        -h | --help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
