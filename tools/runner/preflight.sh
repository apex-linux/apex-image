#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: preflight.sh

The owner's first command on the KVM host, before the builder VM and the runner are set
up (tools/runner/README.md). It changes nothing: one PASS, FAIL or SKIP row per check,
and exit 1 when any row fails.

  kvm          /dev/kvm is readable and writable by this user
  nested-kvm   nested KVM is on: G4's boots run inside the builder VM
  podman       rootless podman 4.4 or later, with pasta
  subids       /etc/subuid and /etc/subgid give this user 65536 ids or more
  cgroup-v2    the unified cgroup hierarchy
  disk         free space where the builder VM lives (APEX_VM_DIR) for its disk to grow
               to a full build (45 GiB), the kernel pair's scratch (25 GiB) and ccache
               (15 GiB), less what its disk already holds
  ram, cpus    the builder VM's APEX_VM_MEM plus 2 GiB for the host, and APEX_VM_CPUS
  net:HOST     HTTPS to GitHub, ghcr.io, Fedora's registry and mirrors, and the COPR
  runner-key   the runner's ssh key, known_hosts and config (after runner.sh key)
  ci-build     the key's forced command in the builder VM (after just vm-ci-install,
               while the VM runs)
  vm-host-key  the runner's known_hosts holds the builder VM's current host key (a new VM,
               after builder-vm.sh destroy and create, has a new one)
  vm-cosign    the builder VM's /usr/local/bin/cosign is the version and sha256 that
               tools/builder-vm/cosign.env pins (while the VM runs)
  time-sync    the clock is synchronised (signatures and tokens check times)
EOF
    exit 2
}

readonly GIB=$((1024 * 1024 * 1024))
readonly BUILD_GIB=45 KERNEL_SCRATCH_GIB=25 CCACHE_GIB=15 HOST_RAM_GIB=2
readonly MIN_SUBIDS=65536
readonly CI_BUILD=/usr/local/libexec/apex/ci-build
readonly VM_COSIGN=/usr/local/bin/cosign
readonly URLS=(
    https://github.com/ https://api.github.com/ https://ghcr.io/v2/
    https://registry.fedoraproject.org/v2/ https://download.fedoraproject.org/pub/fedora/linux/
    https://copr.fedorainfracloud.org/api_3/ https://download.copr.fedorainfracloud.org/results/
)

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${APEX_PREFLIGHT_ROOT:-}
user=$(id -un)
vm_dir=${APEX_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/apex/builder}
ssh_dir=${XDG_CONFIG_HOME:-$HOME/.config}/apex/runner/ssh
ssh_port=${APEX_VM_SSH_PORT:-2222}
builder_vm=${APEX_PREFLIGHT_BUILDER_VM:-$here/../builder-vm/builder-vm.sh}
cosign_env=$here/../builder-vm/cosign.env
fails=0

row() {
    printf '%-4s %-38s %s\n' "$1" "$2" "$3"
    [[ $1 != FAIL ]] || fails=$((fails + 1))
}

check_kvm() {
    if [[ -e $root/dev/kvm && -r $root/dev/kvm && -w $root/dev/kvm ]]; then
        row PASS kvm "/dev/kvm is readable and writable by $user"
    else
        row FAIL kvm "/dev/kvm is missing or not usable by $user: enable virtualisation in the firmware, then the kvm group or its ACL"
    fi
}

check_nested() {
    local f value found=0
    for f in "$root"/sys/module/kvm_intel/parameters/nested "$root"/sys/module/kvm_amd/parameters/nested; do
        [[ -r $f ]] || continue
        found=1
        value=$(<"$f")
        if [[ $value == Y || $value == 1 ]]; then
            row PASS nested-kvm "${f#"$root"} is $value"
            return
        fi
    done
    if ((found)); then
        row FAIL nested-kvm "nested KVM is off, and G4 boots inside the builder VM: options kvm_intel nested=1 (or kvm_amd) in /etc/modprobe.d"
    else
        row FAIL nested-kvm "neither kvm_intel nor kvm_amd is loaded"
    fi
}

check_podman() {
    local version rootless
    if ! command -v podman >/dev/null; then
        row FAIL podman "no podman (Ubuntu: apt install podman passt uidmap; Fedora: dnf install podman passt)"
        return
    fi
    version=$(podman version --format '{{.Client.Version}}' 2>/dev/null)
    rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)
    if [[ -z $version || $(printf '%s\n' 4.4 "$version" | sort -V | head -n 1) != 4.4 ]]; then
        row FAIL podman "podman ${version:-unknown} is older than 4.4, which pasta and keep-id:uid need"
    elif [[ $rootless != true ]]; then
        row FAIL podman "podman info does not run rootless as $user (Rootless: ${rootless:-no answer})"
    elif ! command -v pasta >/dev/null; then
        row FAIL podman "podman $version runs rootless, but there is no pasta (package passt)"
    else
        row PASS podman "podman $version runs rootless as $user, with pasta"
    fi
}

check_subids() {
    local file count bad=()
    for file in subuid subgid; do
        count=$(awk -F: -v u="$user" '$1 == u { n += $3 } END { print n + 0 }' "$root/etc/$file" 2>/dev/null || echo 0)
        ((count >= MIN_SUBIDS)) || bad+=("/etc/$file gives $count")
    done
    if ((${#bad[@]} == 0)); then
        row PASS subids "/etc/subuid and /etc/subgid give $user $MIN_SUBIDS ids or more"
    else
        row FAIL subids "$(IFS=';' && printf '%s' "${bad[*]}") ids to $user, under $MIN_SUBIDS: usermod --add-subuids and --add-subgids"
    fi
}

check_cgroup() {
    if [[ -e $root/sys/fs/cgroup/cgroup.controllers ]]; then
        row PASS cgroup-v2 "/sys/fs/cgroup is the unified hierarchy"
    else
        row FAIL cgroup-v2 "/sys/fs/cgroup is not cgroup v2 (systemd.unified_cgroup_hierarchy=1)"
    fi
}

check_disk() {
    local dir=$vm_dir avail held need
    while [[ ! -d $dir && $dir != / ]]; do dir=$(dirname -- "$dir"); done
    avail=$(df -B1 --output=avail -- "$dir" 2>/dev/null | tail -n 1 | tr -d ' ')
    held=$(du -B1 -- "$vm_dir/disk.qcow2" 2>/dev/null | cut -f1)
    need=$(((BUILD_GIB + KERNEL_SCRATCH_GIB + CCACHE_GIB) * GIB - ${held:-0}))
    ((need > 0)) || need=0
    if [[ -z $avail ]]; then
        row FAIL disk "df cannot read $dir"
    elif ((avail >= need)); then
        row PASS disk "$((avail / GIB)) GiB free at $dir; the builder VM needs $((need / GIB)) GiB more"
    else
        row FAIL disk "$((avail / GIB)) GiB free at $dir; the builder VM's disk needs $((need / GIB)) GiB more ($BUILD_GIB build + $KERNEL_SCRATCH_GIB kernel scratch + $CCACHE_GIB ccache, less ${held:-0} bytes it holds)"
    fi
}

gib_of() {
    case $1 in
        *G) printf '%s\n' "${1%G}" ;;
        *M) printf '%s\n' "$(((${1%M} + 1023) / 1024))" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

check_ram_cpus() {
    local mem=${APEX_VM_MEM:-6G} cpus=${APEX_VM_CPUS:-8} total_kib want have
    total_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$root/proc/meminfo" 2>/dev/null)
    want=$(($(gib_of "$mem") + HOST_RAM_GIB))
    if [[ -z $total_kib ]]; then
        row FAIL ram "cannot read MemTotal in /proc/meminfo"
    elif ((total_kib * 1024 >= want * GIB)); then
        row PASS ram "$((total_kib / 1024 / 1024)) GiB, for the VM's $mem and $HOST_RAM_GIB GiB for the host"
    else
        row FAIL ram "$((total_kib / 1024 / 1024)) GiB, under the VM's $mem and $HOST_RAM_GIB GiB for the host (APEX_VM_MEM)"
    fi
    have=$(nproc 2>/dev/null || echo 0)
    if ((have >= cpus)); then
        row PASS cpus "$have threads for the VM's $cpus vCPUs"
    else
        row FAIL cpus "$have threads, under the VM's $cpus vCPUs (APEX_VM_CPUS)"
    fi
}

check_net() {
    local url host code
    for url in "${URLS[@]}"; do
        host=${url#https://}
        host=${host%%/*}
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -- "$url" 2>/dev/null)
        if [[ -n $code && $code != 000 ]]; then
            row PASS "net:$host" "HTTPS answers ($code)"
        else
            row FAIL "net:$host" "no HTTPS answer from $url (a proxy, firewall or DNS)"
        fi
    done
}

check_runner_key() {
    local mode body line
    if [[ ! -e $ssh_dir/id_ed25519 ]]; then
        row SKIP runner-key "no $ssh_dir/id_ed25519 yet: just runner key makes it"
        row SKIP ci-build "no runner key to look for in the builder VM"
        return
    fi
    mode=$(stat -c %a -- "$ssh_dir/id_ed25519" 2>/dev/null)
    if [[ $mode != 600 || ! -s $ssh_dir/id_ed25519.pub || ! -s $ssh_dir/known_hosts || ! -s $ssh_dir/config ]]; then
        row FAIL runner-key "$ssh_dir needs id_ed25519 (mode 600, it is ${mode:-unreadable}), id_ed25519.pub, known_hosts and config: just runner key"
    else
        row PASS runner-key "$ssh_dir has the key (mode 600), known_hosts and config"
    fi
    if ! "$builder_vm" running 2>/dev/null; then
        row SKIP ci-build "the builder VM is not running (just vm-start), so its authorized_keys cannot be read"
        return
    fi
    body=$(cut -d' ' -f2 "$ssh_dir/id_ed25519.pub" 2>/dev/null)
    line=$("$builder_vm" ssh "grep -F -- '$body' ~/.ssh/authorized_keys" 2>/dev/null | head -n 1)
    if [[ -n $body && $line == "restrict,command=\"$CI_BUILD\" "* ]]; then
        row PASS ci-build "the builder VM binds the runner's key to $CI_BUILD"
    else
        row FAIL ci-build "the builder VM does not bind the runner's key to restrict,command=\"$CI_BUILD\": just vm-ci-install"
    fi
}

host_keys() { ssh-keygen -F "[127.0.0.1]:$ssh_port" -f "$1" 2>/dev/null | awk '!/^#/ { print $(NF - 1), $NF }' | sort; }

check_host_key() {
    local runner_keys vm_keys
    if [[ ! -s $ssh_dir/known_hosts || ! -s $vm_dir/ssh/known_hosts ]]; then
        row SKIP vm-host-key "no runner known_hosts or no builder VM known_hosts yet (just vm-start, then just runner key)"
        return
    fi
    runner_keys=$(host_keys "$ssh_dir/known_hosts")
    vm_keys=$(host_keys "$vm_dir/ssh/known_hosts")
    if [[ -n $vm_keys && $runner_keys == "$vm_keys" ]]; then
        row PASS vm-host-key "the runner knows the builder VM's current host key"
    else
        row FAIL vm-host-key "the runner's known_hosts does not hold the builder VM's current host key: just runner key"
    fi
}

check_cosign() {
    local want_version want_sum out sum version
    want_version=$(sed -n 's/^COSIGN_VERSION=//p' "$cosign_env" 2>/dev/null)
    want_sum=$(sed -n 's/^COSIGN_SHA256=//p' "$cosign_env" 2>/dev/null)
    if [[ -z $want_version || -z $want_sum ]]; then
        row FAIL vm-cosign "$cosign_env pins no COSIGN_VERSION and COSIGN_SHA256"
        return
    fi
    if ! "$builder_vm" running 2>/dev/null; then
        row SKIP vm-cosign "the builder VM is not running (just vm-start), so its cosign cannot be read"
        return
    fi
    out=$("$builder_vm" ssh "sha256sum $VM_COSIGN && $VM_COSIGN version 2>&1" 2>/dev/null)
    sum=$(awk 'NR == 1 { print $1 }' <<<"$out")
    version=$(sed -n 's/^GitVersion:[[:space:]]*//p' <<<"$out")
    if [[ -z $sum ]]; then
        row FAIL vm-cosign "the builder VM has no $VM_COSIGN: builder-vm.sh provision installs cosign $want_version"
    elif [[ $sum != "$want_sum" || $version != "$want_version" ]]; then
        row FAIL vm-cosign "the builder VM's $VM_COSIGN is ${version:-an unknown version} ($sum), not the pinned $want_version ($want_sum): builder-vm.sh provision"
    else
        row PASS vm-cosign "the builder VM's $VM_COSIGN is the pinned $want_version"
    fi
}

check_time() {
    local synced
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [[ $synced == yes ]]; then
        row PASS time-sync "timedatectl: the clock is synchronised"
    else
        row FAIL time-sync "timedatectl says NTPSynchronized=${synced:-unknown}: timedatectl set-ntp true"
    fi
}

main() {
    case ${1:-} in -h | --help) usage ;; "") ;; *) usage ;; esac
    check_kvm
    check_nested
    check_podman
    check_subids
    check_cgroup
    check_disk
    check_ram_cpus
    check_net
    check_runner_key
    check_host_key
    check_cosign
    check_time
    if ((fails > 0)); then
        printf '\npreflight: %d row(s) failed; fix them before the setup in tools/runner/README.md\n' "$fails"
        exit 1
    fi
    printf '\npreflight: every check passed; go on with the setup in tools/runner/README.md\n'
}

main "$@"
