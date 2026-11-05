#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: sign-source.sh REPO SHA

The gates run vm.yml's release signer trusts for SHA, a merge commit on main, printed as
run=ID and content-key=KEY for GITHUB_OUTPUT. SHA must merge a train
("Merge pull request #N from REPO_OWNER/train/..."), and its second parent is the train
head. A run counts only when its workflow file is .github/workflows/gates.yml, its event
pull_request, its head repository REPO and its head the train head, and it concluded
success; the newest such run's gates-record artifact must say sha (the train head),
g1 passed, g2 passed, g4 passed, a 64-hex content-key and rpm-key test:FPR. Anything else
exits 1 with "sign refused: FIELD: ...". The content key is only what the builder VM's
own build must match: ci-build sign recomputes it from main and refuses another.
Needs gh (GH_TOKEN with actions: read), jq and unzip.
EOF
    exit 2
}

refuse() { echo "sign refused: $*" >&2; exit 1; }

(($# == 2)) || usage
repo=$1 sha=$2
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse "repo: '$repo' is not OWNER/NAME"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || refuse "sha: '$sha' is not a full commit sha"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

gh api "repos/$repo/commits/$sha" >"$work/commit.json" || refuse "commit: cannot read $sha"
[[ $(jq '.parents | length' "$work/commit.json") == 2 ]] || refuse "merge: $sha is not a merge commit"
message=$(jq -r '.commit.message' "$work/commit.json" | head -n 1)
[[ $message =~ ^Merge\ pull\ request\ \#[0-9]+\ from\ ${repo%%/*}/train/[A-Za-z0-9._-]+$ ]] ||
    refuse "merge: $sha merges no train ('$message')"
train=$(jq -r '.parents[1].sha' "$work/commit.json")
[[ $train =~ ^[0-9a-f]{40}$ ]] || refuse "merge: $sha names no train head"

gh api "repos/$repo/actions/workflows/gates.yml/runs?head_sha=$train&per_page=100" >"$work/runs.json" ||
    refuse "run: cannot list gates.yml's runs for $train"
# Each run of the train head, with the first field that keeps it from counting (or "ok").
jq -r --arg repo "$repo" --arg train "$train" '
    .workflow_runs[]? | select(.head_sha == $train)
    | [.id,
       (if .path != ".github/workflows/gates.yml" then "path \(.path)"
        elif .event != "pull_request" then "event \(.event)"
        elif .head_repository.full_name != $repo then "head-repo \(.head_repository.full_name)"
        elif .status != "completed" or .conclusion != "success" then "conclusion \(.status)/\(.conclusion)"
        else "ok" end)]
    | @tsv' "$work/runs.json" | sort -rn >"$work/candidates.tsv"
[[ -s $work/candidates.tsv ]] || refuse "run: gates.yml has no run of the train head $train"
run=$(awk -F'\t' '$2 == "ok" { print $1; exit }' "$work/candidates.tsv")
[[ -n $run ]] || refuse "$(head -n 1 "$work/candidates.tsv" | cut -f2-): the newest gates.yml run of $train, $(head -n 1 "$work/candidates.tsv" | cut -f1), does not count, and none does"

gh api "repos/$repo/actions/runs/$run/artifacts?per_page=100" >"$work/artifacts.json" ||
    refuse "record: cannot list run $run's artifacts"
url=$(jq -r '[.artifacts[]? | select(.name == "gates-record" and .expired == false)][0].archive_download_url // empty' \
    "$work/artifacts.json")
[[ -n $url ]] || refuse "record: run $run has no gates-record artifact"
gh api "$url" >"$work/record.zip" || refuse "record: cannot download run $run's gates-record"
unzip -p "$work/record.zip" gates.txt >"$work/gates.txt" 2>/dev/null || refuse "record: run $run's gates-record has no gates.txt"

field() { sed -n "s/^$1 //p" "$work/gates.txt" | tail -n 1; }
[[ $(field sha) == "$train" ]] || refuse "sha: run $run's record is of $(field sha), not the train head $train"
for gate in g1 g2 g4; do
    [[ $(field "$gate") == passed ]] || refuse "$gate: run $run's record says '$(field "$gate")'"
done
key=$(field content-key)
[[ $key =~ ^[0-9a-f]{64}$ ]] || refuse "content-key: run $run's record names '$key'"
[[ $(field rpm-key) =~ ^test:[0-9A-F]{40}$ ]] || refuse "rpm-key: run $run's record says '$(field rpm-key)', not a hosted test key"
printf 'run=%s\ncontent-key=%s\ntrain=%s\n' "$run" "$key" "$train"
