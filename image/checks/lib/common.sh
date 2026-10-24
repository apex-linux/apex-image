# shellcheck shell=sh disable=SC2034 # the checks that source this read the variables

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

FEDORA_45_KEY_FPR=4f50a6114cd5c6976a7f1179655a4b02f577861e
FEDORA_KEYID=${FEDORA_45_KEY_FPR#????????????????????????}
# A rotation changes this pin and the public key the image ships in one reviewed change.
APEX_RPM_KEY_FPR=B9A8301A20A14E732212A4C58DA3252BD6EF25FA
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

# rpm -qi's Signature field is one line in rpm 4, and indented lines after "Signature :" in rpm 6.
signed_by() {
    root_rpm -qi "$2" 2>/dev/null |
        awk '/^Signature[[:space:]]*:/ { on = 1; print; next } on && /^[[:space:]]/ { print; next } { on = 0 }' |
        grep -iq -- "$1"
}

# none, pair or pair-degraded, from rpms.lock as the repos stage reads it.
pair_mode() {
    _lock=$(rootpath /usr/share/apex/rpms.lock)
    if [ ! -f "$_lock" ] || ! awk '$1 == "rpm" && $2 == "kernel-cachyos" { f = 1 } END { exit !f }' "$_lock"; then
        echo none
    elif awk '$1 == "family" && $2 == "kernel-cachyos" { sub(/ reason=.*/, ""); if (/ degraded=nvidia( |$)/) f = 1 } END { exit !f }' "$_lock"; then
        echo pair-degraded
    else
        echo pair
    fi
}

pair_locked() {
    awk -v n="$1" '$1 == "rpm" && $2 == "kernel-cachyos" && $4 == n { print $5; exit }' \
        "$(rootpath /usr/share/apex/rpms.lock)"
}

read_list() {
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# copy_schemas DIR [overrides]: the root's schemas with the enums files they take types
# from, which glib-compile-schemas needs or it skips the schema and still exits 0.
copy_schemas() {
    for _f in "$(rootpath /usr/share/glib-2.0/schemas)"/*.gschema.xml "$(rootpath /usr/share/glib-2.0/schemas)"/*.enums.xml; do
        if [ -f "$_f" ]; then cp "$_f" "$1/"; fi
    done
    if [ "${2:-}" = overrides ]; then
        for _f in "$(rootpath /usr/share/glib-2.0/schemas)"/*.gschema.override; do
            if [ -f "$_f" ]; then cp "$_f" "$1/"; fi
        done
    fi
}

make_tmpdir() {
    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/apex-check.XXXXXX")
    # shellcheck disable=SC2064 # expand now: the path is fixed
    trap "rm -rf '$TMPD'" EXIT
    trap 'exit 130' INT TERM
}
