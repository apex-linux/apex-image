#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane is built on REPOS_BASE: it runs on the glibc of the lane's build containers.
set -eEuo pipefail
# A failure of lane.sh itself exits 1, never a child's status: 3 means a held family.
trap 'exit 1' ERR

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
readonly checkout
# shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
. "$checkout/.github/scripts/lib.sh"

readonly CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/apex-lane
readonly CARGO_VOLUME=apex-lane-cargo
readonly BUILDER=localhost/apex-lane-builder

git_() { git -c safe.directory="$checkout" -C "$checkout" "$@"; }

base=$(containerfile_arg REPOS_BASE)
is_fedora_pin "$base" || die "image/Containerfile REPOS_BASE '$base' is not a registry.fedoraproject.org digest pin"
tree=$(git_ rev-parse -q --verify HEAD:crates/apex-lane) ||
    die "crates/apex-lane is not committed at HEAD; the just pkg-* recipes snapshot the checkout first"
id=$({
    printf 'apex-lane build 1\n'
    git_ rev-parse HEAD:crates/apex-lane HEAD:Cargo.lock HEAD:Cargo.toml
    printf '%s\n' "$base"
    git_ hash-object -- "$checkout/tools/builder-vm/lane.sh"
} | sha256sum | cut -c1-16)
bin=$CACHE/$id/apex-lane

builder_image() {
    local digest=${base##*@sha256:} image old
    image=$BUILDER:${digest:0:12}
    if ! as_root podman image exists "$image"; then
        log "lane.sh: making $image"
        as_root podman rm -f apex-lane-builder-tmp >/dev/null 2>&1 || true
        as_root podman run --name apex-lane-builder-tmp -v "$checkout:/src:ro,z" "$base" \
            /src/.github/scripts/rpms.sh toolchain >&2
        as_root podman commit -q apex-lane-builder-tmp "$image" >/dev/null
        as_root podman rm apex-lane-builder-tmp >/dev/null
        while IFS= read -r old; do
            [[ $old == "$image" ]] || as_root podman rmi "$old" >/dev/null || true
        done < <(as_root podman images --format '{{.Repository}}:{{.Tag}}' "$BUILDER")
    fi
    printf '%s\n' "$image"
}

build() {
    local image src out
    image=$(builder_image)
    mkdir -p -- "$CACHE"
    src=$(mktemp -d)
    out=$(mktemp -d "$CACHE/.build.XXXXXX")
    # shellcheck disable=SC2064 # expand now: the paths are local
    trap "rm -rf -- '$src'; as_root rm -rf -- '$out'" EXIT
    # HEAD, never the working tree; -m so that cargo sees every file as new.
    git_ archive HEAD Cargo.toml Cargo.lock rust-toolchain.toml crates | tar -x -m -C "$src"
    log "lane.sh: building apex-lane (tree $tree) in $image"
    as_root podman run --rm -v "$src:/src:ro,z" -v "$CARGO_VOLUME:/cargo" -v "$out:/out:z" \
        -e CARGO_HOME=/cargo/home -e CARGO_TARGET_DIR=/cargo/target -e APEX_LANE_TREE="$tree" \
        "$image" bash -c 'cargo build --release --locked -p apex-lane --manifest-path /src/Cargo.toml &&
            install -m 0755 /cargo/target/release/apex-lane /out/apex-lane' >&2
    as_root chown -R "$(id -u):$(id -g)" -- "$out"
    [[ $("$out/apex-lane" --version) == *"(tree $tree)" ]] ||
        die "the built apex-lane does not report the tree $tree"
    chmod 0755 -- "$out"
    rm -rf -- "${CACHE:?}/$id"
    mv -T -- "$out" "$CACHE/$id"
    rm -rf -- "$src"
    trap - EXIT
    find "$CACHE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' |
        sort -rn | tail -n +4 | cut -d' ' -f2- | while IFS= read -r old; do rm -rf -- "$old"; done
}

[[ -x $bin ]] || build
if [[ ${1:-} == --path ]]; then
    printf '%s\n' "$bin"
    exit 0
fi
cd -- "$checkout"
exec "$bin" "$@"
