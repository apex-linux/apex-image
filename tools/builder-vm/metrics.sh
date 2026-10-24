#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: metrics.sh OUT STAMP SHA LOCK_DIFF

S4's daily-driver budget for one CI build, run by ci-build in ~/apex-image after the
build; warning-only (tools/runner/README.md). STAMP is the run's start: only files newer
than it count.

  size    when the gates passed, image.sh rechunk, then the layout's compressed size
          (config and layers) and layer count, against the published apex:45: its size,
          the change in percent, and the bytes of layers it does not have (what an
          update downloads)
  boot    G4's _build/qualify/boot.tsv, when this run's G4 wrote one: systemd-analyze's
          phases, greeter (seconds from the kernel to the greeter's shell) and desktop
          (seconds from the login to the user's shell)

OUT gets metrics.tsv (a header and this build's row), history.tsv (the last 30 rows,
kept in APEX_STORE's metrics.tsv) and warnings.tsv ("metric<TAB>message"):
  size       the size grew more than 15 % and LOCK_DIFF changes no family
  userspace, greeter
             more than 20 % above the last build that passed its gates and has the value
A value it cannot get is "-". The exit is 0 unless OUT cannot be written.
EOF
    exit 2
}

readonly SIZE_GROWTH_PCT=15
readonly BOOT_GROWTH_PCT=20
readonly HISTORY_ROWS=30
readonly COLUMNS='finished sha version gates size layers previous_size size_change_pct new_bytes families firmware loader kernel initrd userspace greeter desktop'

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
. "$checkout/.github/scripts/lib.sh"
image_sh=${APEX_METRICS_IMAGE_SH:-$checkout/.github/scripts/image.sh}
previous_ref=${APEX_METRICS_PREVIOUS:-$APEX_REPO_STABLE:$APEX_FEDORA}

newer() { [[ -s $1 && $1 -nt $2 ]]; }

# "SIZE LAYERS" of an image manifest on stdin, the config and the layers; nothing for an index.
manifest_sizes() {
    jq -r 'select(.layers) | "\((.config.size // 0) + ([.layers[].size] | add // 0)) \(.layers | length)"' 2>/dev/null
}

size_columns() {
    local out=$1 now previous size layers prev_size change new
    if ! APEX_PREVIOUS_BUILD=${APEX_PREVIOUS_BUILD:-$previous_ref} "$image_sh" rechunk >"$out/rechunk.log" 2>&1; then
        log "metrics: image.sh rechunk failed (rechunk.log)"
        printf -- '-\t-\t-\t-\t-\n'
        return
    fi
    now=$(as_root skopeo inspect --raw "oci:$checkout/_build/image/oci/apex:latest" 2>/dev/null)
    read -r size layers <<<"$(manifest_sizes <<<"$now")"
    [[ -n ${size:-} ]] || { printf -- '-\t-\t-\t-\t-\n'; return; }
    local -a auth
    mapfile -t auth < <(skopeo_auth_args)
    previous=$(skopeo inspect --raw "${auth[@]}" "docker://$previous_ref" 2>/dev/null)
    read -r prev_size _ <<<"$(manifest_sizes <<<"$previous")"
    if [[ -z ${prev_size:-} || $prev_size == 0 ]]; then
        printf '%s\t%s\t-\t-\t-\n' "$size" "$layers"
        return
    fi
    change=$(awk -v a="$size" -v b="$prev_size" 'BEGIN { printf "%.1f", (a - b) * 100 / b }')
    new=$(jq -r --argjson prev "$previous" \
        '([$prev.layers[].digest]) as $p | [.layers[] | select(.digest as $d | $p | index($d) | not) | .size] | add // 0' \
        <<<"$now" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\n' "$size" "$layers" "$prev_size" "$change" "${new:--}"
}

changed_families() {
    local names
    names=$(sed -n 's/^+family \([^ ]*\) .*/\1/p' "$1" 2>/dev/null | sort -u | paste -sd, -)
    printf '%s\n' "${names:--}"
}

boot_value() { awk -v k="$2" '$1 == k { print $2; found = 1 } END { if (!found) print "-" }' "$1" 2>/dev/null || echo -; }

# The column N's value in the last history row that passed its gates and has one.
last_green() {
    local history=$1 name=$2 col
    col=$(tr ' ' '\n' <<<"$COLUMNS" | grep -nx "$name" | cut -d: -f1)
    awk -F'\t' -v c="$col" 'NR > 1 && $4 == "yes" && $c != "-" { v = $c } END { print v }' "$history" 2>/dev/null
}

warnings() {
    local row=$1 history=$2 families change name value previous
    local -a f
    IFS=$'\t' read -ra f <<<"$row"
    change=${f[7]} families=${f[9]}
    if [[ $change != - && $families == - ]] && awk -v c="$change" -v t="$SIZE_GROWTH_PCT" 'BEGIN { exit !(c > t) }'; then
        printf 'size\tthe image grew %s %% against %s (%s to %s bytes) with no family change in the lane lock\n' \
            "$change" "$previous_ref" "${f[6]}" "${f[4]}"
    fi
    for name in userspace greeter; do
        case $name in userspace) value=${f[14]} ;; greeter) value=${f[15]} ;; esac
        previous=$(last_green "$history" "$name")
        [[ $value != - && -n $previous ]] || continue
        if awk -v a="$value" -v b="$previous" -v t="$BOOT_GROWTH_PCT" 'BEGIN { exit !(a > b * (1 + t / 100)) }'; then
            printf '%s\t%s s, more than %s %% above the last green build'"'"'s %s s\n' "$name" "$value" "$BOOT_GROWTH_PCT" "$previous"
        fi
    done
}

main() {
    (($# == 4)) || usage
    local out=$1 stamp=$2 sha=$3 lock_diff=$4 store=${APEX_STORE:-$HOME/apex-store} version=- gates=no
    local size_cols boot=$checkout/_build/qualify/boot.tsv row phase history header
    mkdir -p -- "$out" || exit 1
    [[ -s $checkout/_build/image/build.env ]] &&
        version=$(bash -c '. "$1" && printf "%s" "${APEX_VERSION:--}"' _ "$checkout/_build/image/build.env")
    if newer "$checkout/_build/gates-passed.txt" "$stamp"; then
        gates=yes
        size_cols=$(size_columns "$out")
    else
        size_cols=$(printf -- '-\t-\t-\t-\t-')
    fi
    row=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" "${version:--}" "$gates" "$size_cols" \
        "$(changed_families "$lock_diff")")
    for phase in firmware loader kernel initrd userspace greeter desktop; do
        if newer "$boot" "$stamp"; then row+=$'\t'$(boot_value "$boot" "$phase"); else row+=$'\t-'; fi
    done
    header=$(tr ' ' '\t' <<<"$COLUMNS")
    history=$store/metrics.tsv
    mkdir -p -- "$store"
    [[ -s $history && $(head -n 1 "$history") == "$header" ]] || printf '%s\n' "$header" >"$history"
    warnings "$row" "$history" >"$out/warnings.tsv"
    printf '%s\n%s\n' "$header" "$row" >"$out/metrics.tsv"
    { head -n 1 "$history"; { tail -n +2 "$history"; printf '%s\n' "$row"; } | tail -n "$HISTORY_ROWS"; } >"$history.new" &&
        mv -f -- "$history.new" "$history"
    cp -- "$history" "$out/history.tsv"
    log "metrics: $(paste -sd' ' <<<"$row")"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
