#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A throwaway spike, never merged: G4's candidate staged in the guest from containers-storage
# (today) against a switch from a registry on the host, on two fresh installs of one image.
set -euo pipefail

readonly IMAGE=${SPIKE_IMAGE:-quay.io/fedora/fedora-bootc:45}
readonly REGISTRY_IMAGE=docker.io/library/registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
readonly CANDIDATE=localhost/apex-candidate:g4 SERVED=127.0.0.1:5000/apex-candidate:g4 GUEST_REF=10.0.2.2:5000/apex-candidate:g4
SPIKE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export QUALIFY_OUT=${RUNNER_TEMP:-/tmp}/stage-spike QUALIFY_MEM=4G QUALIFY_SMP=4 QUALIFY_LAYOUT=to-disk
# shellcheck source=SCRIPTDIR/../scripts/qualify.sh
. "$SPIKE_ROOT/.github/scripts/qualify.sh"

minutes() { awk -v s="$1" 'BEGIN { printf "%.2f", s / 60 }'; }
timed() { # LABEL COMMAND...: run it, add its minutes to the summary table
    local label=$1 t0=$SECONDS
    shift
    "$@"
    summary "| $label | $(minutes $((SECONDS - t0))) |"
}
staged_digest() { vm_ssh 'bootc status --format=json --format-version=1' | jq -er '.status.staged.image.imageDigest'; }
fresh_guest() { # NAME
    drop_disk "$1" 2>/dev/null || true
    timed "$1: install" install_disk "$1" "$IMAGE" "$IMAGE"
    start_vm "$1" "$1"
    timed "$1: boot to ssh" wait_ssh
    vm_ssh 'timeout 600 systemctl is-system-running --wait' >/dev/null || true
}

mkdir -p "$QUALIFY_OUT/logs"
trap 'stop_vm || true; unmount_all; as_root podman rm -f spike-registry >/dev/null 2>&1 || true; [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || cat "$GITHUB_STEP_SUMMARY"' EXIT
ensure_key
podman_pull "$IMAGE"
size=$(as_root podman image inspect --format '{{.Size}}' "$IMAGE")
summary "### Staging spike: $IMAGE ($((size / 1048576)) MiB), $QUALIFY_LAYOUT, $QUALIFY_MEM, $QUALIFY_SMP vCPUs" "" \
    "| Step | Minutes |" "|---|---|"

# Today: the guest exports its booted image into containers-storage and builds on top of it.
fresh_guest storage
booted=$(vm_ssh 'bootc status --format=json --format-version=1' | jq -er '.status.booted.image.imageDigest')
vm_ssh 'mkdir -p /var/tmp/candidate && echo g4 >/var/tmp/candidate/stamp &&
    printf "FROM localhost/bootc\nCOPY stamp /usr/share/apex-spike-stamp\n" >/var/tmp/candidate/Containerfile'
timed "storage: bootc image copy-to-storage (guest)" vm_ssh 'timeout 1800 bootc image copy-to-storage'
timed "storage: podman build (guest)" vm_ssh "timeout 1800 podman build --pull=never --tag $CANDIDATE /var/tmp/candidate"
timed "storage: bootc switch --download-only (guest)" \
    vm_ssh "timeout 3600 bootc switch --transport containers-storage --download-only $CANDIDATE"
storage_digest=$(staged_digest)
stop_vm

# Proposed: the host builds the candidate and serves it; the guest pulls only what it lacks.
t0=$SECONDS
dir=$QUALIFY_OUT/candidate
mkdir -p "$dir" && echo g4 >"$dir/stamp"
printf 'FROM %s\nCOPY stamp /usr/share/apex-spike-stamp\n' "$IMAGE" >"$dir/Containerfile"
timed "registry: podman build (host)" as_root podman build --pull=never --tag "$CANDIDATE" "$dir"
timed "registry: start registry:2 (host)" as_root podman run -d --name spike-registry -p 127.0.0.1:5000:5000 "$REGISTRY_IMAGE"
timed "registry: podman push (host)" as_root podman push --tls-verify=false "$CANDIDATE" "$SERVED"
host_minutes=$(minutes $((SECONDS - t0)))
fresh_guest registry
vm_ssh "mkdir -p /run/apex-qualify && printf '[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n' >/run/apex-qualify/registries.conf &&
    printf '{\"default\":[{\"type\":\"reject\"}],\"transports\":{\"docker\":{\"10.0.2.2:5000\":[{\"type\":\"insecureAcceptAnything\"}]}}}\n' >/run/apex-qualify/policy.json"
since=$(date -u +%FT%TZ)
timed "registry: bootc switch --download-only (guest)" vm_ssh "timeout 3600 env CONTAINERS_REGISTRIES_CONF=/run/apex-qualify/registries.conf \
    CONTAINERS_POLICY_JSON=/run/apex-qualify/policy.json bootc switch --download-only $GUEST_REF"
registry_digest=$(staged_digest)
as_root podman logs --since "$since" spike-registry >"$QUALIFY_OUT/logs/registry.log" 2>&1 || true
fetches() { grep -o '"GET /v2/apex-candidate/blobs/[^"]*" [0-9]* [0-9]*' "$QUALIFY_OUT/logs/registry.log" || true; }
blobs=$(fetches | grep -c . || true)
bytes=$(fetches | awk '{ s += $NF } END { print s + 0 }')
served=$(as_root podman image inspect --format '{{.Digest}}' "$CANDIDATE")
layers=$(as_root podman image inspect --format '{{len .RootFS.Layers}}' "$CANDIDATE")
stop_vm
summary "" "- Booted: $booted" "- Staged from containers-storage: $storage_digest" \
    "- Staged from the registry: $registry_digest (the host's candidate: $served)" \
    "- The guest fetched $blobs blob(s), $((bytes / 1024)) KiB, of the candidate's $layers layers" \
    "- Host-side registry steps together: $host_minutes min"
