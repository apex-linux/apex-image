# shellcheck shell=sh
# Shared helpers for image/checks/*.sh. POSIX sh; sourced, never executed.
#
# Contract for every check script:
#   - `set -eu`, then set CHECK_NAME and source this file;
#   - print one line per assertion, starting with PASS, FAIL, WARN or SKIP;
#   - call `finish` at the end: it exits 1 when any FAIL was printed.
#
# Environment understood by all checks:
#   ROOT            root of the filesystem to inspect (default /: the running image).
#                   Set it to an extracted rootfs to check that instead.
#   APEX_IMAGE_DIR  the repository's image/ directory (default: the parent of the
#                   checks directory), for lists such as image/audit/*.
#
# rpm queries against ROOT use `rpm --root ROOT --dbpath /usr/lib/sysimage/rpm`, the
# F45 rpmdb location, so they also work from a host whose rpm defaults differ.

ROOT=${ROOT:-/}
# Normalise: strip trailing slashes but keep "/" itself.
while [ "$ROOT" != / ] && [ "${ROOT%/}" != "$ROOT" ]; do
    ROOT=${ROOT%/}
done
[ -n "$ROOT" ] || ROOT=/

: "${CHECK_NAME:=check}"
: "${APEX_CHECKS_DIR:?APEX_CHECKS_DIR must be set before sourcing lib/common.sh}"
APEX_IMAGE_DIR=${APEX_IMAGE_DIR:-$APEX_CHECKS_DIR/..}

_apex_failures=0

pass() { printf 'PASS %s: %s\n' "$CHECK_NAME" "$*"; }
warn() { printf 'WARN %s: %s\n' "$CHECK_NAME" "$*"; }
skip() { printf 'SKIP %s: %s\n' "$CHECK_NAME" "$*"; }
fail() {
    printf 'FAIL %s: %s\n' "$CHECK_NAME" "$*"
    _apex_failures=$((_apex_failures + 1))
}

# finish: print the summary line and exit with the check's status.
finish() {
    if [ "$_apex_failures" -gt 0 ]; then
        printf 'FAIL %s: %d failure(s)\n' "$CHECK_NAME" "$_apex_failures"
        exit 1
    fi
    printf 'PASS %s: all assertions passed\n' "$CHECK_NAME"
    exit 0
}

# rootpath ABSPATH: the path of ABSPATH inside ROOT.
rootpath() {
    if [ "$ROOT" = / ]; then
        printf '%s\n' "$1"
    else
        printf '%s%s\n' "$ROOT" "$1"
    fi
}

# unroot PATH: a path under ROOT as it is seen inside ROOT (absolute).
unroot() {
    if [ "$ROOT" = / ]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${1#"$ROOT"}"
    fi
}

# rpmq ARGS...: rpm against the rpmdb of ROOT.
rpmq() {
    if [ "$ROOT" = / ]; then
        rpm "$@"
    else
        rpm --root "$ROOT" --dbpath /usr/lib/sysimage/rpm "$@"
    fi
}

# read_list FILE: the entries of a list file, one per line, with '#' comments,
# surrounding whitespace and blank lines removed.
read_list() {
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# make_tmpdir: create a private scratch directory, removed on exit. Sets TMPD.
make_tmpdir() {
    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/apex-check.XXXXXX")
    # shellcheck disable=SC2064 # expand now: the path is fixed
    trap "rm -rf '$TMPD'" EXIT
    trap 'exit 130' INT TERM
}
