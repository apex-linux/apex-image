# shellcheck shell=sh
# Helpers for image/tests/t-*.sh (TAP output). POSIX sh; sourced, never executed.
#
# Each test file: `. "$(dirname -- "$0")/lib.sh"`, then assertions, then `done_testing`.
# Checks run against fake roots under $T (removed on exit) with the fakes in
# image/tests/fake on PATH; nothing outside $T is written.

set -eu

TESTS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
IMAGE_DIR=$(dirname -- "$TESTS_DIR")
# shellcheck disable=SC2034 # used by the t-*.sh files that source this
REPO_ROOT=$(dirname -- "$IMAGE_DIR")
# shellcheck disable=SC2034 # likewise
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
# skip_all REASON: skip the whole file, or fail it when APEX_IMAGE_TESTS_NO_SKIP=1 (CI
# provides every tool, so a skip there means a test silently stopped running).
skip_all() {
    if [ "${APEX_IMAGE_TESTS_NO_SKIP:-0}" = 1 ]; then
        printf 'not ok 1 - would skip (%s), but APEX_IMAGE_TESTS_NO_SKIP=1\n1..1\n' "$*"
        exit 1
    fi
    printf '1..0 # SKIP %s\n' "$*"
    exit 0
}

# run CMD...: run CMD, keep its output in $T/out and its exit status in RC.
run() {
    RC=0
    "$@" </dev/null >"$T/out" 2>&1 || RC=$?
}

_show() { sed 's/^/#   /' "$T/out"; }

# expect_rc NAME CODE: the last `run` exited with CODE.
expect_rc() {
    if [ "$RC" -eq "$2" ]; then ok "$1"; else not_ok "$1 (exit $RC, expected $2)" && _show; fi
}
# expect_out NAME ERE: the last `run` printed a line matching ERE.
expect_out() {
    if grep -Eq -- "$2" "$T/out"; then ok "$1"; else not_ok "$1 (no line matches /$2/)" && _show; fi
}
# expect_no_out NAME ERE: the last `run` printed no line matching ERE.
expect_no_out() {
    if grep -Eq -- "$2" "$T/out"; then not_ok "$1 (a line matches /$2/)" && _show; else ok "$1"; fi
}
# expect_file NAME ERE FILE: FILE has a line matching ERE.
expect_file() {
    if [ -f "$3" ] && grep -Eq -- "$2" "$3"; then ok "$1"; else not_ok "$1 ($3 has no line matching /$2/)"; fi
}
# expect_true NAME CMD...: CMD succeeds.
expect_true() {
    name=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi
}

done_testing() {
    printf '1..%d\n' "$_tests"
    [ "$_failed" -eq 0 ]
}

# The shell the checks run under: run.sh sets it to the shell of the current pass, so
# the checks are exercised with dash and bash alike (Fedora's /bin/sh is bash).
# shellcheck disable=SC2034 # used by the t-*.sh files that source this
SH=${TEST_SHELL:-sh}

# fake_path: a PATH that finds image/tests/fake first.
fake_path() {
    printf '%s:%s\n' "$FAKE" "$PATH"
}
