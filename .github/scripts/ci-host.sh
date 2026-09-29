#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

Prepare a GitHub-hosted Ubuntu runner for image work. The subcommands that change the
host run only on GitHub Actions.

  ci-host.sh free-disk                  delete preinstalled toolchains we never use
  ci-host.sh storage                    btrfs (zstd) loopback as rootful podman storage,
                                        and APEX_SCRATCH on the other disk
  ci-host.sh podman-conf                rootful podman: sqlite database, temp in the store
  ci-host.sh kvm                        make /dev/kvm usable by the runner user
  ci-host.sh preflight STORE_GB SCRATCH_GB
                                        fail fast unless that much space is free
  ci-host.sh usage STEP                 add a df/du row for STEP to the job summary
EOF
    exit 2
}

readonly STORE=${APEX_CI_STORE:-/var/lib/containers}
# GITHUB_ENV reaches only later steps; preflight and usage in the same step read this.
readonly SCRATCH_RECORD=${RUNNER_TEMP:-/tmp}/apex-scratch

ci_only() {
    in_github_actions || die "ci-host.sh $1 changes the host; it only runs on GitHub Actions runners"
}

export_env() {
    export "$1=$2"
    if [[ -n ${GITHUB_ENV:-} ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_ENV"; fi
}

avail_bytes() { df --output=avail -B1 "$1" | tail -n 1 | tr -d ' '; }

scratch_dir() {
    if [[ -n ${APEX_SCRATCH:-} ]]; then
        printf '%s\n' "$APEX_SCRATCH"
    elif [[ -s $SCRATCH_RECORD ]]; then
        head -n 1 "$SCRATCH_RECORD"
    fi
}
gib() { printf '%s' $(($1 / 1024 / 1024 / 1024)); }

cmd_free_disk() {
    ci_only free-disk
    local before
    before=$(avail_bytes /)
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /usr/local/lib/android
    sudo rm -rf /opt/ghc /usr/local/.ghcup
    sudo rm -rf /opt/hostedtoolcache/CodeQL
    sudo rm -rf /opt/hostedtoolcache/go /opt/hostedtoolcache/PyPy /opt/hostedtoolcache/Ruby
    sudo rm -rf /usr/local/share/boost
    sudo rm -rf /usr/local/share/powershell
    sudo rm -rf /usr/local/share/chromium
    sudo rm -rf /usr/share/swift
    sudo rm -rf /usr/lib/jvm
    sudo rm -rf /usr/local/julia*
    sudo rm -rf /opt/az /opt/microsoft /opt/google /opt/pipx
    if command -v docker >/dev/null 2>&1; then
        sudo docker image prune --all --force >/dev/null || true
    fi
    local after
    after=$(avail_bytes /)
    log "free-disk: / had $(gib "$before") GiB free, now $(gib "$after") GiB"
}

cmd_storage() {
    ci_only storage
    require df losetup truncate
    if ! command -v mkfs.btrfs >/dev/null 2>&1; then
        retry 3 10 sudo apt-get update -qq
        retry 3 10 sudo apt-get install -y -qq btrfs-progs
    fi
    if mountpoint -q "$STORE"; then
        log "storage: $STORE is already a mount point; keeping it"
    else
        local mnt_free root_free backing scratch
        mnt_free=$(avail_bytes /mnt)
        root_free=$(avail_bytes /)
        if ((mnt_free >= root_free)); then
            backing=/mnt
            scratch=/var/tmp/apex-scratch
        else
            backing=/var/tmp
            scratch=/mnt/apex-scratch
        fi
        local size=$(($(avail_bytes "$backing") - 3 * 1024 * 1024 * 1024))
        ((size > 10 * 1024 * 1024 * 1024)) || die "storage: less than 13 GiB free on $backing"
        local img=$backing/apex-containers.btrfs
        sudo truncate -s "$size" "$img"
        local loop
        loop=$(sudo losetup --find --show "$img")
        sudo mkfs.btrfs -q -L apex-containers "$loop"
        sudo mkdir -p "$STORE"
        # discard=async punches holes in the sparse backing file when podman deletes.
        sudo mount -o compress=zstd:1,noatime,discard=async "$loop" "$STORE"
        sudo mkdir -p "$STORE/tmp" "$scratch"
        sudo chown "$(id -u):$(id -g)" "$scratch"
        export_env APEX_SCRATCH "$scratch"
        printf '%s\n' "$scratch" >"$SCRATCH_RECORD"
        log "storage: btrfs on $loop ($(gib "$size") GiB, backed by $backing) at $STORE;" \
            "scratch at $scratch"
    fi
    cmd_podman_conf
}

cmd_podman_conf() {
    ci_only podman-conf
    # sqlite: Fedora 45's podman 6 in `bootc install` containers shares this store and no
    # longer reads BoltDB.
    sudo mkdir -p /etc/containers/containers.conf.d "$STORE/tmp"
    printf '[engine]\ndatabase_backend = "sqlite"\nimage_copy_tmp_dir = "%s/tmp"\n' "$STORE" |
        sudo tee /etc/containers/containers.conf.d/50-apex-ci.conf >/dev/null
}

cmd_kvm() {
    ci_only kvm
    # GitHub's documented way to give the runner user access to /dev/kvm.
    printf '%s\n' 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
        sudo tee /etc/udev/rules.d/99-apex-kvm.rules >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
    sudo udevadm settle || true
    [[ -w /dev/kvm ]] || die "/dev/kvm is not writable after the udev rule; this runner has no usable KVM"
    log "kvm: /dev/kvm is writable"
}

cmd_preflight() {
    (($# == 2)) || die "usage: ci-host.sh preflight STORE_GB SCRATCH_GB"
    local need_store=$1 need_scratch=$2 scratch
    scratch=$(scratch_dir)
    if [[ -z $scratch ]]; then
        warn "no scratch directory recorded (ci-host.sh storage did not run); checking /var/tmp"
        scratch=/var/tmp
    fi
    local store_free scratch_free
    mkdir -p "$scratch" 2>/dev/null || true
    store_free=$(avail_bytes "$STORE")
    scratch_free=$(avail_bytes "$scratch")
    log "preflight: $STORE $(gib "$store_free") GiB free (need $need_store); $scratch" \
        "$(gib "$scratch_free") GiB free (need $need_scratch)"
    local fail=0
    if (($(gib "$store_free") < need_store)); then
        warn "container storage $STORE has $(gib "$store_free") GiB free, below the $need_store GiB this build needs"
        fail=1
    fi
    if (($(gib "$scratch_free") < need_scratch)); then
        warn "scratch $scratch has $(gib "$scratch_free") GiB free, below the $need_scratch GiB this build needs"
        fail=1
    fi
    ((fail == 0)) || die "not enough disk space on this runner; see ADR 0013 (disk budget)"
}

cmd_usage() {
    (($# == 1)) || die "usage: ci-host.sh usage STEP"
    local step=$1 marker=${RUNNER_TEMP:-/tmp}/apex-usage-header
    if [[ ! -e $marker ]]; then
        summary "" "### Disk usage per step" "" \
            "| Step | / used / free (GiB) | store used / free (GiB) | du store (GiB) | du scratch (GiB) |" \
            "|---|---|---|---|---|"
        : >"$marker"
    fi
    df_pair() {
        df --output=used,avail -B1G "$1" 2>/dev/null | tail -n 1 | awk '{printf "%s / %s", $1, $2}'
    }
    du_gib() {
        [[ -d $1 ]] || { printf -- '-'; return; }
        (as_root timeout 300 du -sx -B1G "$1" 2>/dev/null || printf '?\t') | awk '{printf "%s", $1}'
    }
    local scratch
    scratch=$(scratch_dir)
    summary "| $step | $(df_pair /) | $(df_pair "$STORE") | $(du_gib "$STORE") | $(du_gib "${scratch:-/nonexistent}") |"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        free-disk) cmd_free_disk "$@" ;;
        storage) cmd_storage "$@" ;;
        podman-conf) cmd_podman_conf "$@" ;;
        kvm) cmd_kvm "$@" ;;
        preflight) cmd_preflight "$@" ;;
        usage) cmd_usage "$@" ;;
        *) usage ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
