#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: gates.sh build OUT | g2 IMAGE_DIR OUT | g2-stable IMAGE_DIR RUN1 RUN2 | g4 IMAGE_DIR SHARD
       gates.sh record OUT BUILD_DIR STABLE_DIR G2_DIR G2_DIR -- G4_DIR...

The hosted gates (.github/workflows/gates.yml): G1, G2 and G4 on GitHub's runners, before
a merge, with no owner hardware. build, g2, g2-stable and g4 each run in a privileged
fedora:45 (the REPOS_BASE pin), as the builder VM's Fedora does: its podman store and work
tree on GATES_WORK, the runner's second disk, and /dev/kvm passed through. Their paths
are under RUNNER_TEMP.

  build OUT            the components' RPMs, the lane and the image, as build-image.sh builds
                       them, G1 in the image build; then OUT/apex.oci.zst and OUT/build.txt
                       (sha, image-id, content-key, rpm-key, lock-sha256, seconds)
  g2 IMAGE_DIR OUT     one G2 run (apex-gnome's tests/shots/run.sh, G2_RUNS=1) of build's
                       image into OUT/run-1, with OUT/result.txt
  g2-stable IMAGE_DIR RUN1 RUN2
                       stable.sh: RUN2 agrees with RUN1, as G2's two runs must (RUN2/stable.txt)
  g4 IMAGE_DIR SHARD   qualify.sh local-shard SHARD (separate-boot, 3G, 4 vCPUs) into
                       GATES_WORK/g4-SHARD
  record OUT BUILD_DIR STABLE_DIR G2_DIR G2_DIR -- G4_DIR...
                       the shards' rows as one OUT/results.md (qualify.sh g4-merge), and
                       OUT/gates.txt when G1, both G2 runs, their stability and every G4 row
                       passed on build's image; exit 1 otherwise

Every RPM is signed by an ephemeral key made in the build job. Its secret half stays in
GATES_WORK/gnupg and is never uploaded or cached. Its public half replaces the committed
RPM-GPG-KEY-apex in that job's checkout only, which apex-lane requires. The image carries
/usr/share/apex/test-key and the label <prefix>.rpm-key=test:FPR: G1 checks the image
against that key, and publish.sh, image.sh push, cosign and lane.sh promote refuse it.
EOF
    exit 2
}

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
readonly ROOT
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/.github/scripts/lib.sh"
readonly KEY_FILE=image/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex
readonly IMAGE_REF=localhost/apex:build
readonly COMMON_TOOLS=(podman skopeo git-core jq zstd python3 sudo findutils diffutils gawk tar gzip xz
    util-linux procps-ng which file openssl)
readonly BUILD_TOOLS=(buildah gnupg2 rpm-sign cpio rsync)
readonly G4_TOOLS=(qemu-system-x86-core qemu-img edk2-ovmf dosfstools btrfs-progs e2fsprogs openssh-clients
    socat iproute)
TEMP=${RUNNER_TEMP:-/tmp}
readonly TEMP

# PATH: PATH under RUNNER_TEMP, as the container sees it.
inside() {
    [[ $1 == "$TEMP"/* ]] || die "$1 is not under RUNNER_TEMP ($TEMP)"
    printf '/runner/%s\n' "${1#"$TEMP"/}"
}

# SUB ARGS...: SUB in a privileged fedora:45 on GATES_WORK, this checkout at /src.
in_fedora() {
    local work=${GATES_WORK:?GATES_WORK names the work directory, on the second disk} fedora summary='' dev=()
    fedora=$(containerfile_arg REPOS_BASE)
    is_fedora_pin "$fedora" || die "image/Containerfile REPOS_BASE '$fedora' is not a digest pin"
    [[ $1 != g4 || -c /dev/kvm ]] || die "no /dev/kvm on this runner: G4 cannot run (ci-host.sh kvm)"
    # Loop partitions appear in the host's /dev; bootc checks /run/udev against PID 1's root.
    [[ $1 != g4 ]] || dev=(-v /dev:/dev -v /run/udev:/run/udev)
    [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || summary=$(inside "$GITHUB_STEP_SUMMARY")
    # Buildah overlays the build context from /var/tmp, which cannot sit on this container's overlay.
    mkdir -p "$work/var-tmp-$1" "$work/containers-$1"
    sudo podman run --rm --privileged --cgroupns=private --security-opt label=disable --network host \
        -v "$ROOT:/src:z" -v "$work:/work:z" -v "$TEMP:/runner:z" "${dev[@]}" -w /src \
        -v "$work/var-tmp-$1:/var/tmp:z" -v "$work/containers-$1:/var/lib/containers:z" \
        -e GITHUB_ACTIONS -e GITHUB_RUN_NUMBER -e GATES_SHA="${GATES_SHA:-$(git -C "$ROOT" rev-parse HEAD)}" \
        -e GITHUB_STEP_SUMMARY="$summary" \
        "$fedora" /src/.github/scripts/gates.sh in "$@"
}

# In the container: its tools, and podman's store on /work.
cmd_in() {
    local sub=${1:-}
    shift || true
    local -a tools=("${COMMON_TOOLS[@]}")
    [[ -d /work && -d /runner ]] || die "gates.sh in runs in gates.sh's own container"
    case $sub in
        build) tools+=("${BUILD_TOOLS[@]}") ;;
        g4) tools+=("${G4_TOOLS[@]}") ;;
        g2 | g2-stable) ;;
        *) usage ;;
    esac
    retry 3 10 dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${tools[@]}"
    nested_podman
    # The store is /work/containers-SUB, mounted where qualify.sh hands it to bootc.
    mkdir -p /var/lib/containers/storage /work/home
    printf '[storage]\ndriver = "overlay"\ngraphroot = "/var/lib/containers/storage"\nrunroot = "/run/containers/storage"\n' \
        >/etc/containers/storage.conf
    git config --global --add safe.directory '*'
    export HOME=/work/home
    case $sub in
        build) inner_build "$@" ;;
        g2) load "$1"; components; inner_g2 "$2" ;;
        g2-stable) load "$1"; components; inner_g2_stable "$2" "$3" ;;
        g4) load "$1"; components; inner_g4 "$2" ;;
    esac
}

# Nested containers share the job's network (the runner's resolver is 127.0.0.53) and need
# the cgroup controllers, so this container's processes move to a leaf cgroup first.
nested_podman() {
    local cg=/sys/fs/cgroup
    [[ -f $cg/cgroup.controllers ]] || die "no cgroup v2 in gates.sh's container"
    mkdir -p "$cg/init"
    xargs -rn1 <"$cg/cgroup.procs" >"$cg/init/cgroup.procs" || :
    sed -e 's/ / +/g' -e 's/^/+/' "$cg/cgroup.controllers" >"$cg/cgroup.subtree_control" ||
        die "the cgroup controllers cannot be delegated to nested containers"
    grep -qw pids "$cg/cgroup.subtree_control" || die "nested containers get no pids controller"
    mkdir -p /etc/containers/containers.conf.d
    printf '[containers]\nnetns = "host"\n' >/etc/containers/containers.conf.d/50-gates.conf
}

# The secret half never leaves GNUPGHOME; the checkout's public key is the job's own.
ephemeral_key() {
    local home=$1 fpr
    install -d -m 0700 "$home"
    gpg --homedir "$home" --batch --quiet --passphrase '' \
        --quick-gen-key "Apex gates test key (ephemeral, $(date -u +%FT%TZ))" ed25519 sign 1d
    fpr=$(gpg --homedir "$home" --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
    [[ $fpr =~ ^[0-9A-F]{40}$ ]] || die "the ephemeral key has no fingerprint"
    gpg --homedir "$home" --batch --armor --export "$fpr" >"$ROOT/$KEY_FILE"
    printf 'APEX_RPM_KEY_FPR=%s\nAPEX_RPM_GNUPGHOME=%s\n' "$fpr" "$home" >"$home.env"
    printf '%s\n' "$fpr"
}

inner_build() {
    local out=$1 t0=$SECONDS fpr id key lock
    mkdir -p "$out"
    export APEX_STORE=/work/apex-store APEX_RPM_CACHE=/work/rpm-cache XDG_CACHE_HOME=/work/cache
    fpr=$(ephemeral_key /work/gnupg)
    export APEX_RPM_SIGNING_ENV=/work/gnupg.env APEX_TEST_KEY=$fpr
    log "gates: RPMs signed by the ephemeral key $fpr (its secret half stays in /work/gnupg)"
    cd "$ROOT"
    # shellcheck source=SCRIPTDIR/../../tools/builder-vm/build-image.sh
    . tools/builder-vm/build-image.sh
    rm -rf "$BUILD/rpms" "$BUILD/libfprint"
    mkdir -p _build/image
    use_components
    libfprint_args=(--libfprint-dir "$BUILD/libfprint")
    build_inputs
    build_image
    id=$(image_id)
    key=$(sed -n 's/^CONTENT_KEY=//p' _build/image/image.env | tail -n 1)
    lock=$(sha256_of "$LANE_LOCK")
    podman save --format oci-archive "$IMAGE" | zstd -T0 -3 -q -o "$out/apex.oci.zst"
    printf 'sha %s\nimage-id %s\ncontent-key %s\nrpm-key test:%s\nlock-sha256 %s\nseconds %s\n' \
        "$GATES_SHA" "$id" "${key:-unknown}" "$fpr" "$lock" "$((SECONDS - t0))" >"$out/build.txt"
    cat "$out/build.txt"
}

load() {
    local dir=$1 want id
    want=$(sed -n 's/^image-id //p' "$dir/build.txt")
    [[ -n $want ]] || die "$dir/build.txt names no image-id"
    zstd -dc "$dir/apex.oci.zst" | podman load -q >/dev/null
    id=$(podman image inspect --format '{{.Id}}' "$IMAGE_REF") || die "the archive did not load as $IMAGE_REF"
    [[ $id == "$want" ]] || die "the loaded $IMAGE_REF is $id, not the build's $want"
    log "gates: loaded $IMAGE_REF ($id)"
}

components() {
    "$ROOT/tools/components.sh" fetch >&2
    eval "$("$ROOT/tools/components.sh" env)"
}

inner_g2() {
    local out=$1 root
    G2_IMAGE_DIR=$ROOT/image G2_REPOS_BASE=$(containerfile_arg REPOS_BASE)
    export G2_IMAGE_DIR G2_REPOS_BASE
    mkdir -p "$out/runs"
    G2_RUNS=1 G2_OUT_DIR=$out/runs "$APEX_GNOME_SRC/tests/shots/run.sh" "$IMAGE_REF" || true
    root=$(find "$out/runs" -mindepth 1 -maxdepth 1 -type d ! -name latest | sort | tail -n 1)
    [[ -n $root && -s $root/result.txt ]] || die "G2 wrote no result.txt"
    rm -rf -- "$out/run-1"
    cp -a -- "$root/run-1" "$out/run-1"
    cp -- "$root/result.txt" "$out/result.txt"
    rm -rf -- "$out/runs"
    cat "$out/result.txt"
    grep -qx 'status passed' "$out/result.txt"
}

inner_g2_stable() {
    local here=$APEX_GNOME_SRC/tests/shots a b
    a=$(realpath -- "$1") b=$(realpath -- "$2")
    # stable.sh writes compare.js's plan and results under the second run, so only it is writable.
    G2_GJS="podman run --rm --net=none --tmpfs /var/home -v $here:$here:ro,z -v $a:$a:ro,z -v $b:$b:z --entrypoint gjs $IMAGE_REF"
    export G2_GJS
    "$here/stable.sh" "$a" "$b" | tee "$b/stable.txt"
}

inner_g4() {
    local shard=$1 out=/work/g4-$1
    mkdir -p "$out"
    QUALIFY_MEM=3G QUALIFY_SMP=4 QUALIFY_OUT=$out QUALIFY_LAYOUT=separate-boot \
        "$ROOT/.github/scripts/qualify.sh" local-shard "$shard" "$IMAGE_REF"
}

# Every input is checked here, not only each job's exit: a job that never ran leaves no file.
cmd_record() {
    (($# >= 7)) || usage
    local out=$1 build=$2 stable=$3 status=0 d id key rpm_key sha
    shift 3
    local -a g2=() g4=()
    while (($#)) && [[ $1 != -- ]]; do g2+=("$1"); shift; done
    [[ ${1:-} == -- ]] || usage
    shift
    g4=("$@")
    ((${#g2[@]} == 2 && ${#g4[@]} > 0)) || die "record needs two G2 runs and the G4 shards"
    mkdir -p "$out"
    id=$(sed -n 's/^image-id //p' "$build/build.txt" 2>/dev/null)
    key=$(sed -n 's/^content-key //p' "$build/build.txt" 2>/dev/null)
    rpm_key=$(sed -n 's/^rpm-key //p' "$build/build.txt" 2>/dev/null)
    sha=$(sed -n 's/^sha //p' "$build/build.txt" 2>/dev/null)
    [[ -n $id && -n $key && $key != unknown && $sha =~ ^[0-9a-f]{40}$ && $rpm_key == test:* ]] ||
        die "$build/build.txt is missing or incomplete"
    for d in "${g2[@]}"; do
        if [[ $(sed -n 's/^image-id //p' "$d/result.txt" 2>/dev/null) != "$id" ]] || ! grep -qx 'status passed' "$d/result.txt"; then
            echo "G2: $d did not pass on image $id" >&2
            status=1
        fi
    done
    if ! grep -qE '^# [0-9]+ passed, 0 failed' "$stable/stable.txt" 2>/dev/null; then
        echo "G2: $stable/stable.txt does not show the second run agreeing with the first" >&2
        status=1
    fi
    "$ROOT/.github/scripts/qualify.sh" g4-merge "$out" "${g4[@]}" || status=1
    summary "### Gates for \`${sha:0:12}\` (image $id)" "" "| Test | Result | Detail | Layer feature |" \
        "|---|---|---|---|" "$(cat "$out/results.md" 2>/dev/null)"
    ((status == 0)) || { echo "gates: not passed; no record" >&2; return 1; }
    printf 'sha %s\nimage-id %s\ncontent-key %s\nrpm-key %s\ng1 passed\ng2 passed\ng4 passed\n' \
        "$sha" "$id" "$key" "$rpm_key" >"$out/gates.txt"
    cat "$out/gates.txt"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        build) (($# == 1)) || usage; in_fedora build "$(inside "$1")" ;;
        g2) (($# == 2)) || usage; in_fedora g2 "$(inside "$1")" "$(inside "$2")" ;;
        g2-stable) (($# == 3)) || usage; in_fedora g2-stable "$(inside "$1")" "$(inside "$2")" "$(inside "$3")" ;;
        g4) (($# == 2)) || usage; in_fedora g4 "$(inside "$1")" "$2" ;;
        in) cmd_in "$@" ;;
        record) cmd_record "$@" ;;
        *) usage ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
