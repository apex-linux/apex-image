#!/bin/sh
# No private keys in the image (ARCHITECTURE 11, THREAT-MODEL: CI secrets must never
# reach a layer).
#
# Scans the whole rootfs for PEM/OpenSSH/PGP/cosign private key blocks:
# "-----BEGIN <...>PRIVATE KEY" (this covers RSA, EC, PKCS#8, ENCRYPTED, OPENSSH,
# SIGSTORE/COSIGN and "PGP PRIVATE KEY BLOCK") at the start of a line, after
# whitespace (an indented YAML block scalar), after a quote or '=' (a JSON, YAML or env
# string), or after a literal "\n" (a PEM inside a JSON string). A hit is accepted
# only when
#   - the file belongs to an installed RPM that is not one of Apex's own packages
#     (image/packages/apex.txt: they come from the unsigned local repository, and Apex
#     never ships a private key) and its content is unmodified (rpm -V shows no digest
#     change): a test fixture or sample shipped by Fedora; or
#   - its path matches an entry of image/checks/secrets-fixtures.txt (reviewed,
#     should stay empty).
# Anything else (a file no package owns, a file of an Apex package, or a package file
# whose content changed) fails the build. Because CI rechunks the final merged
# filesystem, what this sees is exactly what the published layers contain.
#
# Environment: ROOT, APEX_IMAGE_DIR (see lib/common.sh); SECRETS_FIXTURES overrides the
# fixture list, APEX_PACKAGES_LIST the list of Apex-built packages.
set -eu
CHECK_NAME=secrets
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

FIXTURES=${SECRETS_FIXTURES:-$APEX_CHECKS_DIR/secrets-fixtures.txt}
APEX_PACKAGES=${APEX_PACKAGES_LIST:-$APEX_IMAGE_DIR/packages/apex.txt}
# The marker must follow the start of a line, whitespace, a quote, '=' or a literal
# "\n": binaries that merely contain the string (ssh-keygen, crypto libraries) keep it
# after a NUL byte and do not match, while keys embedded in text formats do.
PATTERN='(^|["'"'"'[:space:]=]|\\n)-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----'

make_tmpdir

# Apex's own packages (the unsigned local repository): an RPM owner among them never
# excuses a key.
if [ -r "$APEX_PACKAGES" ]; then
    read_list "$APEX_PACKAGES" | cut -f1 >"$TMPD/apex-packages"
else
    fail "cannot read the list of Apex-built packages: $APEX_PACKAGES"
    : >"$TMPD/apex-packages"
fi

# Directories to scan: the whole ROOT, minus API/runtime file systems of a running
# container (/proc, /sys, /dev, /run: not part of the image; /run also holds the build
# context mounts). Top-level symlinks (/bin, /lib, /home, /ostree...) are skipped
# because their targets are scanned anyway.
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

# Fixture globs (path patterns inside ROOT), one per line.
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
    rpmq -qf --qf '%{NAME}\n' "$path" 2>/dev/null | grep -v ' ' | sort -u >"$TMPD/owners" || true
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
    # rpm -V prints "<flags> <attr> <path>" for files that differ; '5' in the third
    # column of the flags means the content digest changed.
    changed=$(rpmq -Vf "$path" 2>/dev/null | awk -v p="$path" '
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
