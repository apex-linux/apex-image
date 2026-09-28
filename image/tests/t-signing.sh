#!/bin/sh
# image/checks/signing.sh: every place rpm and dnf5 read signature settings from.
. "$(dirname -- "$0")/lib.sh"

# mkroot NAME: a root with Fedora-like, compliant configuration; prints its path.
mkroot() {
    r=$T/$1
    mkdir -p "$r/etc/rpm" "$r/usr/lib/rpm/macros.d" "$r/etc/yum.repos.d" "$r/etc/dnf" \
        "$r/var/roothome"
    printf '%%_pkgverify_level all\n' >"$r/usr/lib/rpm/macros.d/macros.fedora-verify"
    printf '[fedora]\nname=Fedora\ngpgcheck=1\nrepo_gpgcheck=0\n' >"$r/etc/yum.repos.d/fedora.repo"
    printf '[main]\ninstallonly_limit=3\n' >"$r/etc/dnf/dnf.conf"
    ln -s var/roothome "$r/root"
    printf '%s\n' "$r"
}

signing() {
    run env ROOT="$1" "$SH" "$CHECKS/signing.sh"
}

r=$(mkroot clean)
signing "$r"
expect_rc "a compliant root passes" 0

# add NAME RELPATH CONTENT: a root with one extra file; the check must fail.
bad() {
    r=$(mkroot "$1")
    mkdir -p "$(dirname -- "$r/$2")"
    printf '%s\n' "$3" >"$r/$2"
    signing "$r"
    expect_rc "fails: $1 ($2)" 1
}

# Review finding: repos.override.d is where `dnf5 config-manager setopt` writes.
bad override-etc etc/dnf/repos.override.d/99-config_manager.repo \
    "$(printf '[fedora]\ngpgcheck=0')"
bad override-usr usr/share/dnf5/repos.override.d/50-vendor.repo \
    "$(printf '[*]\npkg_gpgcheck=false')"
bad localpkg etc/dnf/libdnf5.conf.d/20-local.conf "$(printf '[main]\nlocalpkg_gpgcheck=0')"
bad repo-file etc/yum.repos.d/other.repo "$(printf '[other]\ngpgcheck=0')"
# rpm macro files outside /etc/rpm's top level.
bad platform-macros etc/rpm/x86_64-linux/macros '%_pkgverify_level digest'
bad root-rpmmacros var/roothome/.rpmmacros '%_pkgverify_level none'
bad root-xdg-macros var/roothome/.config/rpm/macros '%__vsflags 0xc0c00'
bad etc-macros etc/rpm/macros.zz '%_pkgverify_flags 0x0'
bad nosignature usr/lib/rpm/macros.d/macros.zz '%__rpm_opts --nosignature'
bad macros-verify etc/rpm/macros.verify '%_pkgverify_level all'

# The same file reached through /root and /var/roothome is reported once.
r=$(mkroot once)
mkdir -p "$r/var/roothome/.config/rpm"
printf '%%_pkgverify_level digest\n' >"$r/var/roothome/.config/rpm/macros"
signing "$r"
if [ "$(grep -c '^FAIL signing: .*lowers %_pkgverify_level' "$T/out")" -eq 1 ]; then
    ok "a file seen through /root and /var/roothome is reported once"
else
    not_ok "a file seen through /root and /var/roothome is reported once" && sed 's/^/#   /' "$T/out"
fi

done_testing
