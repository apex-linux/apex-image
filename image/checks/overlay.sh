#!/bin/sh
# Any warning about an overlay file fails: at boot, systemd and udev log a bad line and ignore it.
set -eu
CHECK_NAME=overlay
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

OVERLAY=${OVERLAY_DIR:-$APEX_IMAGE_DIR/system_files}
UNITDIR=usr/lib/systemd/system

make_tmpdir

if [ ! -d "$OVERLAY" ]; then
    fail "overlay source not found: $OVERLAY"
    finish
fi

verify_unit() {
    if [ "$ROOT" = / ]; then
        systemd-analyze verify --man=no --recursive-errors=no "$1"
    else
        systemd-analyze verify --man=no --recursive-errors=no --root="$ROOT" "$1"
    fi
}
verify_rules() {
    if [ "$ROOT" = / ]; then
        udevadm verify --no-summary "$1"
    else
        udevadm verify --no-summary --root="$ROOT" "$1"
    fi
}
# Even with --root, systemd-tmpfiles reads a file named on the command line from the host path.
dry_run_tmpfiles() {
    if [ "$ROOT" = / ]; then
        systemd-tmpfiles --dry-run --create "$1"
    else
        systemd-tmpfiles --dry-run --create --root="$ROOT" "$(rootpath "$1")"
    fi
}

report() {
    kind=$1 target=$2 rc=$3 out=$4 about_target=$5
    if [ "$rc" -ne 0 ]; then
        fail "$kind $target (exit $rc): $(head -n 5 "$out" | paste -sd '|' -)"
    elif grep -Eq -- "$about_target" "$out"; then
        fail "$kind $target: $(grep -E -- "$about_target" "$out" | head -n 5 | paste -sd '|' -)"
    else
        if [ -s "$out" ]; then
            warn "$kind $target: messages about other files: $(head -n 3 "$out" | paste -sd '|' -)"
        fi
        pass "$kind $target"
    fi
}

tool_missing=0
for tool in systemd-analyze udevadm systemd-tmpfiles; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "$tool not found"
        tool_missing=1
    fi
done
[ "$tool_missing" -eq 0 ] || finish

: >"$TMPD/units"
for f in "$OVERLAY/$UNITDIR"/*; do
    [ -f "$f" ] || continue
    case ${f##*/} in
        *.service | *.socket | *.timer | *.path | *.mount | *.target) printf '%s\n' "${f##*/}" >>"$TMPD/units" ;;
    esac
done
# A drop-in is verified through the unit it extends, merged as it is at boot.
for d in "$OVERLAY/$UNITDIR"/*.d; do
    [ -d "$d" ] || continue
    for f in "$d"/*.conf; do
        if [ -f "$f" ]; then
            name=${d##*/}
            printf '%s\n' "${name%.d}" >>"$TMPD/units"
            break
        fi
    done
done
sort -u -o "$TMPD/units" "$TMPD/units"
while IFS= read -r unit; do
    if [ ! -e "$(rootpath "/$UNITDIR/$unit")" ] && [ ! -d "$(rootpath "/$UNITDIR/$unit.d")" ]; then
        fail "unit not installed: /$UNITDIR/$unit"
        continue
    fi
    rc=0
    verify_unit "$unit" </dev/null >"$TMPD/out" 2>&1 || rc=$?
    report "systemd-analyze verify" "$unit" "$rc" "$TMPD/out" "(^|/)$unit(\\.d/|:| )"
done <"$TMPD/units"

for f in "$OVERLAY"/usr/lib/udev/rules.d/*.rules; do
    [ -f "$f" ] || continue
    path=/usr/lib/udev/rules.d/${f##*/}
    rc=0
    verify_rules "$path" </dev/null >"$TMPD/out" 2>&1 || rc=$?
    report "udevadm verify" "$path" "$rc" "$TMPD/out" "${f##*/}"
done

for f in "$OVERLAY"/usr/lib/tmpfiles.d/*.conf; do
    [ -f "$f" ] || continue
    path=/usr/lib/tmpfiles.d/${f##*/}
    rc=0
    # --dry-run logs "Would ..." for every action; any other line is a warning or error.
    dry_run_tmpfiles "$path" </dev/null >"$TMPD/raw" 2>&1 || rc=$?
    grep -v '^Would ' "$TMPD/raw" >"$TMPD/out" || true
    report "systemd-tmpfiles --dry-run" "$path" "$rc" "$TMPD/out" "${f##*/}"
done

finish
