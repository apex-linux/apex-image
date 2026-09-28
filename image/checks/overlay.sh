#!/bin/sh
# The image overlay's own systemd, udev and tmpfiles files validate (ARCHITECTURE 11).
#
# The files are those in image/system_files ($APEX_IMAGE_DIR/system_files), checked as
# installed under ROOT:
#   - units (*.service, *.socket, *.timer, *.path, *.mount, *.target) directly in
#     usr/lib/systemd/system: `systemd-analyze verify`;
#   - drop-ins (usr/lib/systemd/system/<unit>.d/*.conf): `systemd-analyze verify` of the
#     unit they extend, by name, so the drop-in is merged as it is at boot;
#   - udev rules (usr/lib/udev/rules.d/*.rules): `udevadm verify`, style included;
#   - tmpfiles.d files: `systemd-tmpfiles --dry-run --create`.
# Any warning about these files fails: at boot, systemd and udev only log a bad line
# and ignore it, so the image would ship with, for example, the metered-network gate of
# a Flatpak unit or the dGPU runtime-PM rule silently inactive. Messages about other
# units that a verified unit pulls in are shown as WARN.
#
# Not covered here: the GSettings override (validated in the Containerfile against
# the installed schemas), the polkit JavaScript rule (polkit has no offline validator)
# and the apex RPM's own files (packaging's `make check-data`).
#
# Environment: ROOT, APEX_IMAGE_DIR (see lib/common.sh); OVERLAY_DIR overrides the
# overlay source directory.
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

# The three tools, with --root=ROOT unless ROOT is the running image.
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
# systemd-tmpfiles reads a configuration file named on the command line from the host
# path even with --root, so it gets the file's path under ROOT.
dry_run_tmpfiles() {
    if [ "$ROOT" = / ]; then
        systemd-tmpfiles --dry-run --create "$1"
    else
        systemd-tmpfiles --dry-run --create --root="$ROOT" "$(rootpath "$1")"
    fi
}

# report KIND TARGET RC OUTPUT_FILE PATTERN: PASS, or FAIL with the output. Output lines
# that do not match PATTERN (another unit's messages) only WARN when RC is 0.
report() {
    kind=$1 target=$2 rc=$3 out=$4 pattern=$5
    if [ "$rc" -ne 0 ]; then
        fail "$kind $target (exit $rc): $(head -n 5 "$out" | paste -sd '|' -)"
    elif grep -Eq -- "$pattern" "$out"; then
        fail "$kind $target: $(grep -E -- "$pattern" "$out" | head -n 5 | paste -sd '|' -)"
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

# --- systemd units and drop-ins --------------------------------------------------
: >"$TMPD/units"
for f in "$OVERLAY/$UNITDIR"/*; do
    [ -f "$f" ] || continue
    case ${f##*/} in
        *.service | *.socket | *.timer | *.path | *.mount | *.target) printf '%s\n' "${f##*/}" >>"$TMPD/units" ;;
    esac
done
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

# --- udev rules ------------------------------------------------------------------
for f in "$OVERLAY"/usr/lib/udev/rules.d/*.rules; do
    [ -f "$f" ] || continue
    path=/usr/lib/udev/rules.d/${f##*/}
    rc=0
    verify_rules "$path" </dev/null >"$TMPD/out" 2>&1 || rc=$?
    report "udevadm verify" "$path" "$rc" "$TMPD/out" "${f##*/}"
done

# --- tmpfiles.d ------------------------------------------------------------------
for f in "$OVERLAY"/usr/lib/tmpfiles.d/*.conf; do
    [ -f "$f" ] || continue
    path=/usr/lib/tmpfiles.d/${f##*/}
    rc=0
    # --dry-run logs "Would create ..." for every action; anything else is a warning
    # or an error.
    dry_run_tmpfiles "$path" </dev/null >"$TMPD/raw" 2>&1 || rc=$?
    grep -v '^Would ' "$TMPD/raw" >"$TMPD/out" || true
    report "systemd-tmpfiles --dry-run" "$path" "$rc" "$TMPD/out" "${f##*/}"
done

finish
