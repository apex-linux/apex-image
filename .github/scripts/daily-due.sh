#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

Whether vm.yml's daily run builds, from the Actions API's answers saved as files.

  daily-due.sh RUNS_JSON JOBS_JSON RUN_ID SHA NOW

RUNS_JSON is GET .../actions/workflows/vm.yml/runs, JOBS_JSON {"jobs": [...]} with the
jobs of the runs of SHA; RUN_ID is this run, NOW seconds since the epoch. Prints one line:
"skip: WHY" when another vm.yml run is queued, waiting, pending or running, or a build of
SHA started under 20 h ago and gave a verdict: it succeeded, or failed with its step "A
gate gave its verdict" run. "due: WHY" otherwise, also when a file is not the API's
answer, so a failed lookup builds.
EOF
    exit 2
}

readonly BUILD_JOB='builder VM build and gates' VERDICT_STEP='A gate gave its verdict' WINDOW_S=$((20 * 3600))

main() {
    (($# == 5)) || usage
    local runs=$1 jobs=$2 run_id=$3 sha=$4 now=$5 active built
    [[ $run_id =~ ^[0-9]+$ && $sha =~ ^[0-9a-f]{40}$ && $now =~ ^[0-9]+$ ]] || usage
    if ! jq -e '.workflow_runs | type == "array"' "$runs" >/dev/null 2>&1; then
        echo "due: the vm.yml runs could not be read, so the daily builds"
        return 0
    fi
    active=$(jq -r --argjson self "$run_id" '
        [.workflow_runs[] | select(.id != $self and
            (.status | IN("queued", "waiting", "pending", "in_progress", "requested")))][0]
        // empty | "run \(.id) (\(.event), \(.head_sha[0:12])) is \(.status)"' "$runs")
    if [[ -n $active ]]; then
        echo "skip: vm.yml $active, and builds main as new as this daily would"
        return 0
    fi
    if ! jq -e '.jobs | type == "array"' "$jobs" >/dev/null 2>&1; then
        echo "due: the jobs of ${sha:0:12}'s runs could not be read, so the daily builds"
        return 0
    fi
    built=$(jq -r --argjson self "$run_id" --arg sha "$sha" --arg name "$BUILD_JOB" --arg verdict "$VERDICT_STEP" \
        --argjson now "$now" --argjson window "$WINDOW_S" '
        [.jobs[] | select(.name == $name and .head_sha == $sha and .run_id != $self and .started_at != null
            and (.conclusion == "success"
                or (.conclusion == "failure" and any(.steps[]?; .name == $verdict and .conclusion == "success")))
            and $now - (.started_at | fromdateiso8601) < $window)
        ] | max_by(.started_at) // empty
        | "run \(.run_id) built it \(($now - (.started_at | fromdateiso8601)) / 3600 | floor) h ago (\(.conclusion))"' "$jobs")
    if [[ -n $built ]]; then
        echo "skip: ${sha:0:12} is main's head and vm.yml $built"
        return 0
    fi
    echo "due: no build of ${sha:0:12} started in the last 20 h and gave a verdict"
}

main "$@"
