# shellcheck shell=sh
# Sourced by image/checks/*.sh after `set -eu` and CHECK_NAME. Each check prints one PASS,
# FAIL, WARN or SKIP line per assertion and ends with `finish`, which exits 1 on a FAIL.

ROOT=${ROOT:-/}
while [ "$ROOT" != / ] && [ "${ROOT%/}" != "$ROOT" ]; do
    ROOT=${ROOT%/}
done
[ -n "$ROOT" ] || ROOT=/

: "${CHECK_NAME:=check}"
: "${APEX_CHECKS_DIR:?APEX_CHECKS_DIR must be set before sourcing lib/common.sh}"
APEX_IMAGE_DIR=${APEX_IMAGE_DIR:-$APEX_CHECKS_DIR/..}

# Named explicitly so that a host rpm with other defaults reads ROOT's database.
FEDORA_RPMDB=/usr/lib/sysimage/rpm

_apex_failures=0

pass() { printf 'PASS %s: %s\n' "$CHECK_NAME" "$*"; }
warn() { printf 'WARN %s: %s\n' "$CHECK_NAME" "$*"; }
skip() { printf 'SKIP %s: %s\n' "$CHECK_NAME" "$*"; }
fail() {
    printf 'FAIL %s: %s\n' "$CHECK_NAME" "$*"
    _apex_failures=$((_apex_failures + 1))
}

finish() {
    if [ "$_apex_failures" -gt 0 ]; then
        printf 'FAIL %s: %d failure(s)\n' "$CHECK_NAME" "$_apex_failures"
        exit 1
    fi
    printf 'PASS %s: all assertions passed\n' "$CHECK_NAME"
    exit 0
}

rootpath() {
    if [ "$ROOT" = / ]; then
        printf '%s\n' "$1"
    else
        printf '%s%s\n' "$ROOT" "$1"
    fi
}

unroot() {
    if [ "$ROOT" = / ]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${1#"$ROOT"}"
    fi
}

root_rpm() {
    if [ "$ROOT" = / ]; then
        rpm "$@"
    else
        rpm --root "$ROOT" --dbpath "$FEDORA_RPMDB" "$@"
    fi
}

read_list() {
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# Sets TMPD to a private scratch directory, removed on exit.
make_tmpdir() {
    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/apex-check.XXXXXX")
    # shellcheck disable=SC2064 # expand now: the path is fixed
    trap "rm -rf '$TMPD'" EXIT
    trap 'exit 130' INT TERM
}
