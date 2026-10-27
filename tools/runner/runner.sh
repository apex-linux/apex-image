#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
The self-hosted runner of apex-image's vm.yml, on the host that runs the builder VM
(tools/runner/README.md). Each job gets a just-in-time (JIT) runner in a fresh rootless
podman container, which is removed after that one job; the systemd user service
apex-runner.service keeps one runner waiting. No sudo, and no root on the host.

  runner.sh group      create or update the runner group apex-kvm through the API, check
                       it, and print the settings to click where the API cannot set them
  runner.sh key        make the runner's ssh key, known_hosts and config for the builder VM
  runner.sh image      build the runner image (a pinned actions/runner, SHA-256 checked)
  runner.sh check      a throwaway container: the builder VM's ci-build answers, and no
                       other port of this host's loopback is reachable
  runner.sh install    install and start apex-runner.service
  runner.sh once       one JIT runner for one job (what the service runs), once the
                       builder VM's sshd answers
  runner.sh status     the service, the waiting container and the group's runners
  runner.sh uninstall  stop and remove the service (keeps the key, the token and the image)

Files, in ~/.config/apex/runner/:
  token     the fine-grained token (organisation permission "Self-hosted runners: read
            and write", repository access apex-image only), mode 0600
  ssh/      id_ed25519, known_hosts and config, mounted read-only into each container

Environment (defaults in brackets):
  APEX_RUNNER_ORG   [apex-linux]
  APEX_RUNNER_REPO  [apex-image]
  APEX_VM_DIR       [~/.local/share/apex/builder]  the builder VM, for its host key
  APEX_VM_SSH_PORT  [2222]                         its sshd on this host's 127.0.0.1
EOF
}

readonly RUNNER_VERSION=2.338.0
readonly RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
readonly IMAGE=localhost/apex-runner:$RUNNER_VERSION
readonly API=https://api.github.com
readonly API_VERSION=2022-11-28
readonly GROUP=apex-kvm
readonly LABEL=apex-kvm
readonly UNIT=apex-runner.service
BUILDER_POLL=30 BUILDER_LOG_EVERY=600

ORG=${APEX_RUNNER_ORG:-apex-linux}
REPO=${APEX_RUNNER_REPO:-apex-image}
WORKFLOW=$ORG/$REPO/.github/workflows/vm.yml@refs/heads/main
VM_DIR=${APEX_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/apex/builder}
SSH_PORT=${APEX_VM_SSH_PORT:-2222}
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/apex/runner
TOKEN_FILE=$CONFIG_DIR/token
SSH_DIR=$CONFIG_DIR/ssh
INSTALL_DIR=$HOME/.local/share/apex/runner
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly ORG REPO WORKFLOW VM_DIR SSH_PORT CONFIG_DIR TOKEN_FILE SSH_DIR INSTALL_DIR UNIT_DIR HERE

log() { printf '[runner] %s\n' "$*" >&2; }
die() { printf '[runner] error: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local t missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
}

token() {
    [[ -s $TOKEN_FILE ]] || die "no token in $TOKEN_FILE (tools/runner/README.md, step 1)"
    [[ $(stat -c %a "$TOKEN_FILE") == 600 ]] || die "$TOKEN_FILE must be mode 0600"
    tr -d '[:space:]' <"$TOKEN_FILE"
}

# The token goes to curl on stdin, never in argv.
api() {
    local method=$1 path=$2 body=${3-}
    local args=(-sS --fail-with-body -X "$method" -K -
        -H 'Accept: application/vnd.github+json' -H "X-GitHub-Api-Version: $API_VERSION")
    [[ -z $body ]] || args+=(-H 'Content-Type: application/json' --data-binary "$body")
    printf 'header = "Authorization: Bearer %s"\n' "$(token)" | curl "${args[@]}" "$API$path"
}

group_id() {
    api GET "/orgs/$ORG/actions/runner-groups?per_page=100" |
        jq -r --arg name "$GROUP" '.runner_groups[] | select(.name == $name) | .id'
}

print_group_settings() {
    local public=$1
    cat <<EOF

Set by hand (github.com, as an owner of $ORG):

  $ORG > Settings > Actions > Runner groups > $GROUP (or New runner group, named $GROUP):
    Repository access:           Selected repositories, only $REPO
    Allow public repositories:   $([[ $public == true ]] && echo "on ($REPO is public)" || echo off)
    Workflow access:             Selected workflows, only
                                 $WORKFLOW
EOF
}

print_repo_settings() {
    cat <<EOF

Set by hand, always: the token has no administration rights for them.

  $ORG > Settings > Actions > General:
    Fork pull request workflows from outside collaborators: Require approval for all
    outside collaborators
  $ORG/$REPO > Settings > Environments > New environment "vm-dispatch":
    Required reviewers:           the owner
    Deployment branches and tags: Selected branches and tags, only main
EOF
}

group_matches() {
    local id=$1 repo_full=$2 public=$3 group repos
    group=$(api GET "/orgs/$ORG/actions/runner-groups/$id") || return 1
    repos=$(api GET "/orgs/$ORG/actions/runner-groups/$id/repositories?per_page=100" |
        jq -c '[.repositories[].full_name]') || return 1
    jq -e --arg wf "$WORKFLOW" --argjson public "$public" \
        '.visibility == "selected" and .restricted_to_workflows == true and .selected_workflows == [$wf]
         and .allows_public_repositories == $public' <<<"$group" >/dev/null &&
        [[ $repos == "[\"$repo_full\"]" ]]
}

cmd_group() {
    require_tools curl jq
    local repo_json repo_id repo_full public id settings
    repo_json=$(api GET "/repos/$ORG/$REPO") ||
        die "the token cannot read $ORG/$REPO: give it repository access to $REPO only"
    repo_id=$(jq -r .id <<<"$repo_json")
    repo_full=$(jq -r .full_name <<<"$repo_json")
    public=$(jq -r '.private | not' <<<"$repo_json")
    settings=$(jq -nc --argjson public "$public" --arg wf "$WORKFLOW" \
        '{visibility: "selected", allows_public_repositories: $public,
          restricted_to_workflows: true, selected_workflows: [$wf]}')
    id=$(group_id) || die "the token cannot list $ORG's runner groups: it needs \"Self-hosted runners: read and write\""
    if [[ -z $id ]]; then
        log "creating the runner group $GROUP"
        id=$(api POST "/orgs/$ORG/actions/runner-groups" \
            "$(jq -c --arg name "$GROUP" --argjson repo "$repo_id" '. + {name: $name, selected_repository_ids: [$repo]}' <<<"$settings")" |
            jq -r .id) || id=
    else
        log "updating the runner group $GROUP (id $id)"
        api PATCH "/orgs/$ORG/actions/runner-groups/$id" "$settings" >/dev/null || true
        api PUT "/orgs/$ORG/actions/runner-groups/$id/repositories" "{\"selected_repository_ids\":[$repo_id]}" >/dev/null || true
    fi
    if [[ -n $id ]] && group_matches "$id" "$repo_full" "$public"; then
        log "runner group $GROUP: only $repo_full, only $WORKFLOW"
        print_repo_settings
        return 0
    fi
    log "the API did not set the runner group as required; the organisation's plan may not offer"
    log "workflow access for runner groups. Set it by hand, then run runner.sh group again."
    print_group_settings "$public"
    print_repo_settings
    return 1
}

cmd_key() {
    require_tools ssh-keygen
    local host_key
    mkdir -p "$SSH_DIR"
    chmod 0700 "$CONFIG_DIR" "$SSH_DIR"
    [[ -s $SSH_DIR/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C apex-runner -f "$SSH_DIR/id_ed25519"
    host_key=$(ssh-keygen -F "[127.0.0.1]:$SSH_PORT" -f "$VM_DIR/ssh/known_hosts" 2>/dev/null | grep -v '^#') ||
        die "no host key of the builder VM in $VM_DIR/ssh/known_hosts: start it once (just vm-start)"
    printf '%s\n' "$host_key" >"$SSH_DIR/known_hosts"
    cat >"$SSH_DIR/config" <<EOF
Host apex-builder
    HostName 127.0.0.1
    Port $SSH_PORT
    User builder
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/known_hosts
    StrictHostKeyChecking yes
    BatchMode yes
    ServerAliveInterval 30
    ServerAliveCountMax 10
EOF
    chmod 0600 "$SSH_DIR"/*
    log "key $(ssh-keygen -l -f "$SSH_DIR/id_ed25519.pub" | cut -d' ' -f2); next: just vm-ci-install"
}

cmd_image() {
    require_tools podman
    podman build --pull=missing -t "$IMAGE" \
        --build-arg RUNNER_VERSION="$RUNNER_VERSION" --build-arg RUNNER_SHA256="$RUNNER_SHA256" \
        -f "$HERE/Containerfile" "$HERE"
}

# Only the builder VM's ssh port of this host's loopback is forwarded into the container.
container_args() {
    local name=$1
    printf '%s\n' --rm --name "$name" --userns=keep-id:uid=1000,gid=1000 \
        --network="pasta:-T,$SSH_PORT,--no-map-gw" \
        --cap-drop=all --security-opt=no-new-privileges --pids-limit=1024 --memory=4g \
        -v "$SSH_DIR:/home/runner/.ssh:ro,Z"
}

require_ready() {
    require_tools pasta
    local version
    version=$(podman version --format '{{.Client.Version}}')
    [[ $(printf '%s\n' 4.4 "$version" | sort -V | head -1) == 4.4 ]] ||
        die "podman $version is too old: pasta and keep-id:uid need 4.4 or later (Ubuntu 24.04, Fedora 38)"
    [[ -s $SSH_DIR/config && -s $SSH_DIR/known_hosts ]] || die "no runner ssh config in $SSH_DIR (runner.sh key)"
    podman image exists "$IMAGE" || die "no image $IMAGE (runner.sh image)"
}

cmd_check() {
    require_tools podman
    require_ready
    local args rc=0
    mapfile -t args < <(container_args "apex-runner-check-$$")
    podman run "${args[@]}" --entrypoint /bin/bash "$IMAGE" -c '
        set -u
        ssh apex-builder >/dev/null 2>&1 </dev/null; rc=$?
        if [[ $rc != 2 ]]; then echo "ssh apex-builder exited $rc, expected 2: ci-build refusing an empty request"; exit 1; fi
        echo "ci-build answers, and refuses a request without a commit"
        gw=$(awk '\''$2 == "00000000" {print $3; exit}'\'' /proc/net/route)
        gw=$((16#${gw:6:2})).$((16#${gw:4:2})).$((16#${gw:2:2})).$((16#${gw:0:2}))
        for host in 127.0.0.1 "$gw" 169.254.1.2; do
            if timeout 3 bash -c "</dev/tcp/$host/2223" 2>/dev/null; then echo "$host:2223 is reachable"; exit 1; fi
        done
        echo "the desktop VM port 2223 of the host is unreachable at 127.0.0.1, the gateway $gw and 169.254.1.2"' || rc=$?
    ((rc == 0)) || die "check failed"
    log "check passed"
}

# QEMU's forwarded port accepts a connection while the guest is down and then resets it,
# so only sshd's banner shows the builder VM can take a build.
builder_answers() {
    local banner
    # shellcheck disable=SC2016 # expanded by the inner bash
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" && head -c 4 <&3' _ "$SSH_PORT" 2>/dev/null) || true
    [[ $banner == SSH- ]]
}

wait_for_builder() {
    local waited=0
    until builder_answers; do
        ((waited % BUILDER_LOG_EVERY)) ||
            log "the builder VM's sshd (127.0.0.1:$SSH_PORT) does not answer; no job is taken until it does (just vm-start)"
        sleep "$BUILDER_POLL"
        waited=$((waited + BUILDER_POLL))
    done
}

cmd_once() {
    require_tools podman curl jq
    require_ready
    wait_for_builder
    local id name response runner_id env_file args
    id=$(group_id)
    [[ -n $id ]] || die "no runner group $GROUP in $ORG (runner.sh group)"
    name=$LABEL-$(date -u +%Y%m%d%H%M%S)-$RANDOM
    response=$(api POST "/orgs/$ORG/actions/runners/generate-jitconfig" \
        "$(jq -nc --arg name "$name" --argjson group "$id" --arg label "$LABEL" \
            '{name: $name, runner_group_id: $group, labels: ["self-hosted", "Linux", "X64", $label], work_folder: "_work"}')")
    runner_id=$(jq -r .runner.id <<<"$response")
    env_file=$(mktemp)
    # shellcheck disable=SC2064 # expand now: the values are local
    trap "rm -f -- '$env_file'; podman rm -f '$name' >/dev/null 2>&1; api DELETE '/orgs/$ORG/actions/runners/$runner_id' >/dev/null 2>&1 || true" EXIT
    trap 'exit 143' TERM INT
    jq -r '"APEX_RUNNER_JIT=" + .encoded_jit_config' <<<"$response" >"$env_file"
    mapfile -t args < <(container_args "$name")
    podman create "${args[@]}" --env-file "$env_file" "$IMAGE" >/dev/null
    rm -f -- "$env_file"
    log "runner $name (id $runner_id) waits for one job"
    podman start --attach "$name"
}

cmd_install() {
    require_tools podman systemctl loginctl
    require_ready
    token >/dev/null
    install -D -m 0755 "$HERE/runner.sh" "$INSTALL_DIR/runner.sh"
    install -m 0644 "$HERE/Containerfile" "$INSTALL_DIR/Containerfile"
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=Apex self-hosted runner: one just-in-time runner per job (tools/runner/README.md)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=APEX_RUNNER_ORG=$ORG APEX_RUNNER_REPO=$REPO APEX_VM_DIR=$VM_DIR APEX_VM_SSH_PORT=$SSH_PORT
ExecStart=$INSTALL_DIR/runner.sh once
Restart=always
RestartSec=15
TimeoutStopSec=90

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT"
    log "started $UNIT"
    [[ $(loginctl show-user "$(id -un)" -P Linger 2>/dev/null) == yes ]] ||
        log "to keep it running without a login, run yourself: sudo loginctl enable-linger $(id -un)"
}

cmd_status() {
    local id
    systemctl --user --no-pager status "$UNIT" || true
    podman ps --filter "name=^$LABEL-" --format '{{.Names}} {{.Status}}' || true
    id=$(group_id) && [[ -n $id ]] &&
        api GET "/orgs/$ORG/actions/runner-groups/$id/runners?per_page=100" |
        jq -r '.runners[] | "\(.name) \(.status) busy=\(.busy)"'
}

cmd_uninstall() {
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
    rm -f -- "$UNIT_DIR/$UNIT"
    systemctl --user daemon-reload
    rm -rf -- "$INSTALL_DIR"
    log "removed $UNIT; $CONFIG_DIR and $IMAGE stay"
}

main() {
    [[ $(id -u) -ne 0 ]] || die "run as your normal user: the runner is rootless"
    local cmd=${1:-help}
    shift || true
    (($# == 0)) || die "runner.sh $cmd takes no arguments"
    case $cmd in
        group) cmd_group ;;
        key) cmd_key ;;
        image) cmd_image ;;
        check) cmd_check ;;
        install) cmd_install ;;
        once) cmd_once ;;
        status) cmd_status ;;
        uninstall) cmd_uninstall ;;
        help | -h | --help) usage ;;
        *) die "unknown command '$cmd' (runner.sh help)" ;;
    esac
}

[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
