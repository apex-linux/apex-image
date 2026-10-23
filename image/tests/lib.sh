# shellcheck shell=sh disable=SC2034 # the t-*.sh files that source this read the variables

set -eu

TESTS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
IMAGE_DIR=$(dirname -- "$TESTS_DIR")
REPO_ROOT=$(dirname -- "$IMAGE_DIR")
# The component checkouts; until the split, this one holds them all.
APEX_SYSTEM_SRC=${APEX_SYSTEM_SRC:-$REPO_ROOT}
APEX_DESKTOP_SRC=${APEX_DESKTOP_SRC:-$REPO_ROOT}
CHECKS=$IMAGE_DIR/checks
FAKE=$TESTS_DIR/fake
T=$(mktemp -d "${TMPDIR:-/tmp}/apex-image-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT TERM

_tests=0
_failed=0

ok() {
    _tests=$((_tests + 1))
    printf 'ok %d - %s\n' "$_tests" "$*"
}
not_ok() {
    _tests=$((_tests + 1))
    _failed=$((_failed + 1))
    printf 'not ok %d - %s\n' "$_tests" "$*"
}
# CI has every tool, so there a skip means a test silently stopped running.
skip_all() {
    if [ "${APEX_IMAGE_TESTS_NO_SKIP:-0}" = 1 ]; then
        printf 'not ok 1 - would skip (%s), but APEX_IMAGE_TESTS_NO_SKIP=1\n1..1\n' "$*"
        exit 1
    fi
    printf '1..0 # SKIP %s\n' "$*"
    exit 0
}

run() {
    RC=0
    "$@" </dev/null >"$T/out" 2>&1 || RC=$?
}

_show() { sed 's/^/#   /' "$T/out"; }

expect_rc() {
    if [ "$RC" -eq "$2" ]; then ok "$1"; else not_ok "$1 (exit $RC, expected $2)" && _show; fi
}
expect_out() {
    if grep -Eq -- "$2" "$T/out"; then ok "$1"; else not_ok "$1 (no line matches /$2/)" && _show; fi
}
expect_no_out() {
    if grep -Eq -- "$2" "$T/out"; then not_ok "$1 (a line matches /$2/)" && _show; else ok "$1"; fi
}
expect_file() {
    if [ -f "$3" ] && grep -Eq -- "$2" "$3"; then ok "$1"; else not_ok "$1 ($3 has no line matching /$2/)"; fi
}
expect_true() {
    name=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi
}

done_testing() {
    printf '1..%d\n' "$_tests"
    [ "$_failed" -eq 0 ]
}

# run.sh's shell for this pass: the checks must run under dash and bash alike.
SH=${TEST_SHELL:-sh}

fake_path() {
    printf '%s:%s\n' "$FAKE" "$PATH"
}
