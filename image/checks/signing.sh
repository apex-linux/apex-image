#!/bin/sh
# Fedora 45's rpm signature enforcement stays on: no rpm macro file and no dnf5
# configuration, repository or override in the image weakens it.
set -eu
CHECK_NAME=signing
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

if [ -e "$(rootpath /etc/rpm/macros.verify)" ]; then
    fail "/etc/rpm/macros.verify exists (it overrides signature enforcement)"
else
    pass "no /etc/rpm/macros.verify"
fi

# On bootc /root is a symlink to /var/roothome, so a file can be listed twice.
macro_files() {
    for d in /etc/rpm /usr/lib/rpm/macros.d; do
        for f in "$(rootpath "$d")"/*; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done
    done
    for f in "$(rootpath /etc/rpm)"/*/macros; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    for home in /var/roothome /root; do
        for f in "$(rootpath "$home")/.rpmmacros" "$(rootpath "$home")/.config/rpm/macros"; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done
    done
    return 0
}

make_tmpdir
macro_files >"$TMPD/macros.all"
: >"$TMPD/macros"
while IFS= read -r f; do
    real=$(readlink -f -- "$f" 2>/dev/null || printf '%s' "$f")
    if ! grep -Fxq -- "$real" "$TMPD/macros.real" 2>/dev/null; then
        printf '%s\n' "$real" >>"$TMPD/macros.real"
        printf '%s\n' "$f" >>"$TMPD/macros"
    fi
done <"$TMPD/macros.all"
n=$(wc -l <"$TMPD/macros" | tr -d ' ')
bad=0
while IFS= read -r f; do
    rel=$(unroot "$f")
    if grep -Eq '^[[:space:]]*%_pkgverify_level[[:space:]]+' "$f" &&
        grep -E '^[[:space:]]*%_pkgverify_level[[:space:]]+' "$f" | grep -Evq '^[[:space:]]*%_pkgverify_level[[:space:]]+all[[:space:]]*$'; then
        fail "$rel lowers %_pkgverify_level"
        bad=1
    fi
    if grep -Eq '^[[:space:]]*%(_pkgverify_flags|_?_vsflags[A-Za-z_]*)[[:space:]]' "$f"; then
        fail "$rel redefines %_pkgverify_flags or %_vsflags"
        bad=1
    fi
    if grep -Eq -e '--(nosignature|nodigest)' "$f"; then
        fail "$rel mentions --nosignature/--nodigest"
        bad=1
    fi
done <"$TMPD/macros"
if [ "$bad" -eq 0 ]; then
    pass "no verification overrides in $n rpm macro file(s)"
fi

: >"$TMPD/dnfconf"
for pat in /etc/dnf/dnf.conf '/etc/dnf/libdnf5.conf.d/*.conf' '/usr/share/dnf5/libdnf.conf.d/*.conf' \
    '/etc/yum.repos.d/*.repo' '/etc/distro.repos.d/*.repo' '/usr/share/dnf5/repos.d/*.repo' \
    '/etc/dnf/repos.override.d/*.repo' '/usr/share/dnf5/repos.override.d/*.repo'; do
    # shellcheck disable=SC2086 # glob expansion on purpose
    for f in $(rootpath "$pat"); do
        [ -f "$f" ] && printf '%s\n' "$f" >>"$TMPD/dnfconf"
    done
done
bad=0
while IFS= read -r f; do
    if grep -Eiq '^[[:space:]]*((local)?pkg_)?gpgcheck[[:space:]]*=[[:space:]]*(0|false|no|off)[[:space:]]*$' "$f"; then
        fail "$(unroot "$f") disables package signature checking (gpgcheck, pkg_gpgcheck or localpkg_gpgcheck)"
        bad=1
    fi
done <"$TMPD/dnfconf"
if [ "$bad" -eq 0 ]; then
    pass "no dnf configuration, repository or override disables gpgcheck ($(wc -l <"$TMPD/dnfconf" | tr -d ' ') file(s))"
fi

finish
