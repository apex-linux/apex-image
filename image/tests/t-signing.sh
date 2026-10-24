#!/bin/sh
# image/checks/signing.sh: every place rpm and dnf5 read signature settings from, the
# shipped Apex RPM key and the signatures of Apex's packages.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found (the fake rpm)"
command -v gpg >/dev/null 2>&1 || skip_all "gpg not found (the check reads the Apex RPM key with it)"

KEY=$IMAGE_DIR/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex
APEX='EdDSA/SHA512, Tue 29 Sep 2026 07:00:00 AM UTC, Key ID 8da3252bd6ef25fa'
FEDORA='RSA/SHA256, Mon 14 Sep 2026 10:00:00 AM UTC, Key ID 655a4b02f577861e'

# rpmdb FILE [NAME=RELEASE:SIGNATURE...]: the image's Apex packages and a Fedora one; each
# edit replaces one package's release and signature.
rpmdb() {
    python3 - "$@" <<'PY'
import json, os, sys
apex, fedora = os.environ["APEX"], os.environ["FEDORA"]
db = {
    "apex": {"evr": "0.1.0-0.20260929.gitaae8564aaaaa.fc45", "signature": apex},
    "apex-desktop": {"evr": "0.1.0-0.20260929.gitaae8564aaaaa.fc45", "arch": "noarch",
                     "signature": apex},
    "libfprint": {"evr": "1.94.10-1.fc45.apex1", "signature": apex},
    "gnome-shell": {"evr": "51.0-1.fc45.apex4", "signature": apex},
    "mutter": {"evr": "51.0-1.fc45", "signature": fedora},
}
for edit in sys.argv[2:]:
    name, rest = edit.split("=", 1)
    release, signature = rest.split(":", 1)
    pkg = db.setdefault(name, {})
    pkg["evr"] = pkg.get("evr", "1-1").rsplit("-", 1)[0] + "-" + release
    pkg["signature"] = {"apex": apex, "fedora": fedora}.get(signature, signature)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(db, f)
PY
}

# mkroot NAME: prints the path of a root with Fedora-like, compliant configuration.
mkroot() {
    r=$T/$1
    mkdir -p "$r/etc/rpm" "$r/usr/lib/rpm/macros.d" "$r/etc/yum.repos.d" "$r/etc/dnf" \
        "$r/var/roothome" "$r/usr/share/apex/keys"
    printf '%%_pkgverify_level all\n' >"$r/usr/lib/rpm/macros.d/macros.fedora-verify"
    printf '[fedora]\nname=Fedora\ngpgcheck=1\nrepo_gpgcheck=0\n' >"$r/etc/yum.repos.d/fedora.repo"
    printf '[main]\ninstallonly_limit=3\n' >"$r/etc/dnf/dnf.conf"
    ln -s var/roothome "$r/root"
    cp "$KEY" "$r/usr/share/apex/keys/RPM-GPG-KEY-apex"
    APEX=$APEX FEDORA=$FEDORA rpmdb "$T/$1.db"
    printf '%s\n' "$r"
}

signing() {
    run env PATH="$(fake_path)" FAKE_RPMDB="$T/$1.db" ROOT="$T/$1" "$SH" "$CHECKS/signing.sh"
}

r=$(mkroot clean)
signing clean
expect_rc "a compliant root passes" 0
expect_out "the shipped key is the pinned Apex RPM key" \
    '^PASS signing: /usr/share/apex/keys/RPM-GPG-KEY-apex is the Apex RPM key B9A8301A20A14E732212A4C58DA3252BD6EF25FA$'
for p in apex apex-desktop libfprint gnome-shell; do
    expect_out "$p carries the Apex signature" "^PASS signing: $p [^ ]* carries the Apex RPM signature \\(8DA3252BD6EF25FA\\)\$"
done
expect_no_out "Fedora's mutter is not Apex's" '^[A-Z]+ signing: mutter '

# bad NAME RELPATH CONTENT: a root with that one extra file fails the check.
bad() {
    r=$(mkroot "$1")
    mkdir -p "$(dirname -- "$r/$2")"
    printf '%s\n' "$3" >"$r/$2"
    signing "$1"
    expect_rc "fails: $1 ($2)" 1
}

# `dnf5 config-manager setopt` writes to repos.override.d.
bad override-etc etc/dnf/repos.override.d/99-config_manager.repo \
    "$(printf '[fedora]\ngpgcheck=0')"
bad override-usr usr/share/dnf5/repos.override.d/50-vendor.repo \
    "$(printf '[*]\npkg_gpgcheck=false')"
bad localpkg etc/dnf/libdnf5.conf.d/20-local.conf "$(printf '[main]\nlocalpkg_gpgcheck=0')"
bad repo-file etc/yum.repos.d/other.repo "$(printf '[other]\ngpgcheck=0')"
bad platform-macros etc/rpm/x86_64-linux/macros '%_pkgverify_level digest'
bad root-rpmmacros var/roothome/.rpmmacros '%_pkgverify_level none'
bad root-xdg-macros var/roothome/.config/rpm/macros '%__vsflags 0xc0c00'
bad etc-macros etc/rpm/macros.zz '%_pkgverify_flags 0x0'
bad nosignature usr/lib/rpm/macros.d/macros.zz '%__rpm_opts --nosignature'
bad macros-verify etc/rpm/macros.verify '%_pkgverify_level all'

r=$(mkroot once)
mkdir -p "$r/var/roothome/.config/rpm"
printf '%%_pkgverify_level digest\n' >"$r/var/roothome/.config/rpm/macros"
signing once
if [ "$(grep -c '^FAIL signing: .*lowers %_pkgverify_level' "$T/out")" -eq 1 ]; then
    ok "a file seen through /root and /var/roothome is reported once"
else
    not_ok "a file seen through /root and /var/roothome is reported once" && sed 's/^/#   /' "$T/out"
fi

r=$(mkroot nokey)
rm "$r/usr/share/apex/keys/RPM-GPG-KEY-apex"
signing nokey
expect_rc "an image without the Apex RPM key fails" 1
expect_out "and says so" '^FAIL signing: no /usr/share/apex/keys/RPM-GPG-KEY-apex'
r=$(mkroot twokeys)
cat "$KEY" >>"$r/usr/share/apex/keys/RPM-GPG-KEY-apex"
signing twokeys
expect_rc "a key file with a second key fails" 1
expect_out "and names what it holds" '^FAIL signing: .* holds \[B9A8301A20A14E732212A4C58DA3252BD6EF25FA B9A8301A20A14E732212A4C58DA3252BD6EF25FA\], not the Apex RPM key'
r=$(mkroot notakey)
printf 'APEX-PLACEHOLDER-NOT-A-KEY\n' >"$r/usr/share/apex/keys/RPM-GPG-KEY-apex"
signing notakey
expect_rc "a key file that is no key fails" 1
expect_out "and says so" '^FAIL signing: .* is not an OpenPGP public key'

r=$(mkroot unsigned)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/unsigned.db" 'apex-desktop=0.20260929.gitaae8564aaaaa.fc45:(none)'
signing unsigned
expect_rc "an unsigned Apex package fails" 1
expect_out "and names it" '^FAIL signing: apex-desktop 0\.20260929\.gitaae8564aaaaa\.fc45 is not signed by the Apex RPM key'
r=$(mkroot fedoraapex)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/fedoraapex.db" 'gnome-shell=1.fc45.apex4:fedora'
signing fedoraapex
expect_rc "an .apexN release with Fedora's signature fails" 1
expect_out "and names it" '^FAIL signing: gnome-shell 1\.fc45\.apex4 is not signed by the Apex RPM key'
r=$(mkroot stockfprint)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/stockfprint.db" 'libfprint=1.fc45:fedora'
signing stockfprint
expect_rc "Fedora's libfprint (degraded=fingerprint) passes" 0
expect_out "and is named" "^PASS signing: libfprint 1\\.fc45 is Fedora's build, signed by Fedora's key\$"
F46='RSA/SHA256, Mon 14 Sep 2026 10:00:00 AM UTC, Key ID 96e7e91491211fce'
r=$(mkroot next)
mkdir -p "$r/usr/lib" && printf 'NAME="Fedora Linux"\nVERSION_ID=46\n' >"$r/usr/lib/os-release"
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/next.db" "libfprint=1.fc46:$F46"
signing next
expect_rc "a Fedora 46 root takes Fedora 46's key (the next lane)" 0
expect_out "for its stock libfprint" "^PASS signing: libfprint 1\\.fc46 is Fedora's build, signed by Fedora's key\$"
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/next.db" 'libfprint=1.fc46:fedora'
signing next
expect_rc "and not Fedora 45's" 1
r=$(mkroot fedoraapexfprint)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/fedoraapexfprint.db" 'libfprint=1.fc45.apex1:fedora'
signing fedoraapexfprint
expect_rc "an .apexN libfprint with Fedora's signature fails" 1
expect_out "and names it" '^FAIL signing: libfprint 1\.fc45\.apex1 is not signed by the Apex RPM key'
r=$(mkroot unsignedfprint)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/unsignedfprint.db" 'libfprint=1.fc45:(none)'
signing unsignedfprint
expect_rc "an unsigned stock libfprint fails" 1
expect_out "and names it" '^FAIL signing: libfprint 1\.fc45 is not signed by the Apex RPM key'
r=$(mkroot otherkey)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/otherkey.db" 'apex=0.20260929.gitaae8564aaaaa.fc45:EdDSA/SHA512, Key ID 0123456789abcdef'
signing otherkey
expect_rc "an Apex package signed by another key fails" 1
expect_out "and names it" '^FAIL signing: apex 0\.20260929\.gitaae8564aaaaa\.fc45 is not signed by the Apex RPM key'
r=$(mkroot fedoradesktop)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/fedoradesktop.db" 'apex-desktop=0.20260929.gitaae8564aaaaa.fc45:fedora'
signing fedoradesktop
expect_rc "only libfprint may be Fedora's: a Fedora-signed apex-desktop fails" 1
expect_out "and names it" '^FAIL signing: apex-desktop 0\.20260929\.gitaae8564aaaaa\.fc45 is not signed by the Apex RPM key'
r=$(mkroot unsignedshell)
APEX=$APEX FEDORA=$FEDORA rpmdb "$T/unsignedshell.db" 'gnome-shell-common=1.fc45.apex4:(none)'
signing unsignedshell
expect_rc "an unsigned .apexN package that apex.txt does not name fails" 1
expect_out "and names it" '^FAIL signing: gnome-shell-common 1\.fc45\.apex4 is not signed by the Apex RPM key'

done_testing
