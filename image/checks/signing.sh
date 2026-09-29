#!/bin/sh
# Fedora 45's rpm signature enforcement stays on: no rpm macro file and no dnf5
# configuration, repository or override in the image weakens it. The image ships the
# Apex RPM key, and every package Apex builds carries its signature.
set -eu
CHECK_NAME=signing
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

APEX_RPM_KEY=/usr/share/apex/keys/RPM-GPG-KEY-apex

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

key=$(rootpath "$APEX_RPM_KEY")
if [ ! -s "$key" ]; then
    fail "no $APEX_RPM_KEY: the public half of the Apex RPM key"
elif ! command -v gpg >/dev/null 2>&1; then
    fail "gpg not found: $APEX_RPM_KEY cannot be read"
else
    mkdir -m 0700 "$TMPD/gnupg"
    rc=0
    gpg --homedir "$TMPD/gnupg" --batch --quiet --with-colons --show-keys -- "$key" \
        >"$TMPD/key" 2>"$TMPD/key.err" || rc=$?
    # The fpr record after pub is the primary key's; one after sub is a subkey's.
    fprs=$(awk -F: '$1 == "pub" { want = 1; next }
        $1 == "fpr" && want { print $10; want = 0 }
        $1 == "sub" || $1 == "sec" || $1 == "ssb" { want = 0 }' "$TMPD/key" | paste -sd ' ' -)
    if [ "$rc" -ne 0 ]; then
        fail "$APEX_RPM_KEY is not an OpenPGP public key (gpg exit $rc): $(head -n 3 "$TMPD/key.err" | paste -sd '|' -)"
    elif [ "$fprs" = "$APEX_RPM_KEY_FPR" ]; then
        pass "$APEX_RPM_KEY is the Apex RPM key $APEX_RPM_KEY_FPR"
    else
        fail "$APEX_RPM_KEY holds [${fprs}], not the Apex RPM key $APEX_RPM_KEY_FPR alone"
    fi
fi

# Apex builds apex.txt's packages and every .apexN release. Only libfprint has a Fedora
# fallback: when its rebuild degrades, the image takes Fedora's (degraded=fingerprint).
if ! root_rpm -qa --qf '%{NAME} %{RELEASE}\n' >"$TMPD/installed" 2>"$TMPD/rpm.err"; then
    fail "rpm -qa failed: $(head -n 3 "$TMPD/rpm.err" | paste -sd '|' -)"
else
    read_list "$APEX_IMAGE_DIR/packages/apex.txt" >"$TMPD/own"
    awk 'NR == FNR { own[$1] = 1; next } own[$1] || $2 ~ /\.apex[0-9]/' \
        "$TMPD/own" "$TMPD/installed" | sort -u >"$TMPD/apex-built"
    [ -s "$TMPD/apex-built" ] || fail "no installed package is Apex's (image/packages/apex.txt, .apexN)"
    while read -r name release; do
        if signed_by "$APEX_RPM_KEYID" "$name"; then
            pass "$name $release carries the Apex RPM signature ($APEX_RPM_KEYID)"
        elif [ "$name" = libfprint ] && ! printf '%s\n' "$release" | grep -q '\.apex[0-9]' &&
            signed_by "$FEDORA_KEYID" "$name"; then
            pass "$name $release is Fedora's build, signed by Fedora's key"
        else
            fail "$name $release is not signed by the Apex RPM key ($APEX_RPM_KEYID)"
        fi
    done <"$TMPD/apex-built"
fi

finish
