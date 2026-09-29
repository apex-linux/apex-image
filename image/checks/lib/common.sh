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

# Fedora 45's signing key, fingerprint 4F50 A611 4CD5 C697 6A7F 1179 655A 4B02 F577 861E.
# shellcheck disable=SC2034 # used by the checks that source this
FEDORA_KEYID=655a4b02f577861e
# The Apex RPM key (packaging/README.md, Signing). A rotation changes this pin and the
# public key the image ships in one reviewed change.
APEX_RPM_KEY_FPR=553A938903DFFEEA647F7CC4ABEF111D1FCF882B
# shellcheck disable=SC2034 # likewise
APEX_RPM_KEYID=${APEX_RPM_KEY_FPR#????????????????????????}

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

# signed_by KEYID NAME: the installed NAME carries a signature by KEYID. The Signature
# field of rpm -qi is one line in rpm 4 and indented lines after "Signature :" in rpm 6.
signed_by() {
    root_rpm -qi "$2" 2>/dev/null |
        awk '/^Signature[[:space:]]*:/ { on = 1; print; next } on && /^[[:space:]]/ { print; next } { on = 0 }' |
        grep -iq -- "$1"
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
