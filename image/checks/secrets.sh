#!/bin/sh
# No private key block in the image, except in an unmodified file of a non-Apex package
# or a reviewed fixture.
set -eu
CHECK_NAME=secrets
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

FIXTURES=${SECRETS_FIXTURES:-$APEX_CHECKS_DIR/secrets-fixtures.txt}
APEX_PACKAGES=${APEX_PACKAGES_LIST:-$APEX_IMAGE_DIR/packages/apex.txt}
# Keys embedded in YAML, JSON or env text follow whitespace, a quote, '=' or a literal
# "\n"; binaries that merely contain the string (ssh-keygen) have a NUL byte there.
PATTERN='(^|["'"'"'[:space:]=]|\\n)-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----'

make_tmpdir

# Apex builds these packages itself, so owning a file never excuses it.
if [ -r "$APEX_PACKAGES" ]; then
    read_list "$APEX_PACKAGES" | cut -f1 >"$TMPD/apex-packages"
else
    fail "cannot read the list of Apex-built packages: $APEX_PACKAGES"
    : >"$TMPD/apex-packages"
fi

# /proc, /sys, /dev and /run are not part of the image (/run holds the build context);
# the targets of top-level symlinks are scanned anyway.
: >"$TMPD/dirs"
if [ "$ROOT" = / ]; then
    for d in /* /.[!.]*; do
        [ -e "$d" ] || continue
        [ -L "$d" ] && continue
        case $d in /proc | /sys | /dev | /run) continue ;; esac
        printf '%s\n' "$d" >>"$TMPD/dirs"
    done
else
    printf '%s\n' "$ROOT" >>"$TMPD/dirs"
fi

rc=0
# shellcheck disable=SC2046 # one argument per line of the dirs file; no spaces at top level
grep -rlE -D skip --binary-files=text -e "$PATTERN" $(cat "$TMPD/dirs") >"$TMPD/hits" 2>"$TMPD/grep.err" || rc=$?
case $rc in
    0 | 1) ;;
    *) warn "grep reported errors (first lines): $(head -n 3 "$TMPD/grep.err" | paste -sd ' ' -)" ;;
esac

: >"$TMPD/fixtures"
if [ -r "$FIXTURES" ]; then
    read_list "$FIXTURES" | cut -f1 >"$TMPD/fixtures"
fi

is_fixture() {
    while IFS= read -r pat; do
        # shellcheck disable=SC2254 # pattern match on purpose
        case $1 in $pat) return 0 ;; esac
    done <"$TMPD/fixtures"
    return 1
}

total=0
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    total=$((total + 1))
    path=$(unroot "$hit")
    if is_fixture "$path"; then
        pass "reviewed fixture: $path"
        continue
    fi
    root_rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null | grep -v ' ' | sort -u >"$TMPD/owners" || true
    owner=$(paste -sd ',' "$TMPD/owners")
    if [ -z "$owner" ]; then
        fail "private key in a file no package owns: $path"
        continue
    fi
    apex_owner=$(grep -Fxf "$TMPD/apex-packages" "$TMPD/owners" | paste -sd ',' - || true)
    if [ -n "$apex_owner" ]; then
        fail "private key in a file of an Apex-built package ($apex_owner): $path"
        continue
    fi
    # rpm -V prints "<flags> <attr> <path>"; a '5' as the third flag is a changed digest.
    changed=$(root_rpm -Vf "$path" 2>/dev/null | awk -v p="$path" '
        { f = $NF }
        f == p && ($1 == "missing" || substr($1, 3, 1) == "5") { print "yes" }' || true)
    if [ -n "$changed" ]; then
        fail "private key in a package file whose content was modified: $path ($owner)"
    else
        pass "packaged, unmodified file from $owner: $path"
    fi
done <"$TMPD/hits"

if [ "$total" -eq 0 ]; then
    pass "no private key blocks found"
fi

finish
