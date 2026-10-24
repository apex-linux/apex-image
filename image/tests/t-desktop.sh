#!/bin/sh
# image/checks/desktop.sh on fake roots with the committed schema and crash guard units.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found (the fake rpm)"
command -v glib-compile-schemas >/dev/null 2>&1 || skip_all "glib-compile-schemas not found"
command -v systemd-analyze >/dev/null 2>&1 || skip_all "systemd-analyze not found"
[ -x /usr/bin/gsettings ] || skip_all "no /usr/bin/gsettings (systemd-analyze checks apex-shell-safe.service's ExecStart)"

DESKTOP=$APEX_DESKTOP_SRC/desktop
NKEYS=$(find "$DESKTOP/dconf/distro.d" -maxdepth 1 -type f -exec cat {} + | grep -cvE '^[[:space:]]*(#|\[|$)')
SHA=$(printf '%064d' 0 | tr 0 a)
KEYDIR=pkgs/gnome-shell/gnome-shell-51.0-1.fc45-s0123456789ab

write_lane_lock() {
    {
        printf '# apex rpms.lock 1: written by apex-lane (packaging/README.md, "rpms.lock")\n'
        printf 'family gnome-shell %s gnome-shell-51.0-1.fc45-s0123456789ab\n' "$2"
        case $2 in
            built | held)
                printf 'rpm gnome-shell built gnome-shell gnome-shell-0:51.0-1.fc45.apex1.x86_64 %s %s/gnome-shell-51.0-1.fc45.apex1.x86_64.rpm\n' "$SHA" "$KEYDIR"
                printf 'rpm gnome-shell built gnome-shell-common gnome-shell-common-0:51.0-1.fc45.apex1.noarch %s %s/gnome-shell-common-51.0-1.fc45.apex1.noarch.rpm\n' "$SHA" "$KEYDIR"
                printf 'rpm gnome-shell mirror mutter mutter-0:51.0-1.fc45.x86_64 %s %s/mutter-51.0-1.fc45.x86_64.rpm\n' "$SHA" "$KEYDIR"
                printf 'rpm gnome-shell mirror mutter-common mutter-common-0:51.0-1.fc45.noarch %s %s/mutter-common-51.0-1.fc45.noarch.rpm\n' "$SHA" "$KEYDIR"
                ;;
        esac
    } >"$1"
}

# add_ptyxis LOCK STATE: the family the Apex terminal series adds to the lane.
add_ptyxis() {
    printf 'family ptyxis %s ptyxis-51.0-1.fc45-s0123456789ab\n' "$2" >>"$1"
    case $2 in
        built | held)
            printf 'rpm ptyxis built ptyxis ptyxis-0:51.0-1.fc45.apex1.x86_64 %s pkgs/ptyxis/ptyxis-51.0-1.fc45-s0123456789ab/ptyxis-51.0-1.fc45.apex1.x86_64.rpm\n' "$SHA" >>"$1"
            ;;
    esac
}

# rpmdb FILE [NAME.FIELD=VALUE...]: each edit sets one field, as JSON when it starts
# with [ or ".
rpmdb() {
    python3 - "$@" <<'PY'
import json, sys
fedora = "RSA/SHA256, Mon Sep 14 2026 10:00:00 AM UTC, Key ID 655a4b02f577861e"
apex = "EdDSA/SHA512, Tue Sep 29 2026 07:00:00 AM UTC, Key ID 8da3252bd6ef25fa"
theme = "/usr/share/gnome-shell/gnome-shell-theme.gresource"
db = {
    "gnome-shell": {"evr": "51.0-1.fc45.apex1", "files": [theme], "signature": apex,
                    "requires": ["mutter(x86-64) >= 51.0", "mutter(x86-64) = 51.0-1.fc45"]},
    "gnome-shell-common": {"evr": "51.0-1.fc45.apex1", "arch": "noarch", "signature": apex},
    "mutter": {"evr": "51.0-1.fc45", "signature": fedora},
    "mutter-common": {"evr": "51.0-1.fc45", "arch": "noarch", "signature": fedora},
    "ptyxis": {"evr": "51.0-1.fc45", "signature": fedora},
    "apex-desktop": {"evr": "0.1.0-0.fc45", "arch": "noarch", "signature": apex,
                     "files": ["/etc/profile.d/apex-prompt.sh"]},
}
for edit in sys.argv[2:]:
    key, value = edit.split("=", 1)
    name, field = key.rsplit(".", 1)
    db.setdefault(name, {})[field] = json.loads(value) if value[:1] in '["' else value
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(db, f)
PY
}

# upstream_schemas DIR OVERRIDE: a stub schema per group of OVERRIDE, its keys typed
# from their values, for Fedora's schemas.
upstream_schemas() {
    python3 - "$@" <<'PY'
import configparser, sys
ini = configparser.ConfigParser(interpolation=None)
ini.optionxform = str
ini.read(sys.argv[2], encoding="utf-8")
def gtype(v):
    if v in ("true", "false"):
        return "b"
    if v.startswith("[("):
        return "a(" + "s" * (v.split(")")[0].count(",") + 1) + ")"
    return "as" if v.startswith("[") else "s"
for group in ini.sections():
    keys = "".join(f'<key name="{k}" type="{gtype(v)}"><default><![CDATA[{v}]]></default></key>'
                   for k, v in ini[group].items())
    with open(f"{sys.argv[1]}/{group}.gschema.xml", "w", encoding="utf-8") as f:
        f.write(f'<schemalist><schema id="{group}" path="/{group.replace(".", "/")}/">{keys}</schema></schemalist>\n')
PY
}

# mkroot NAME [LOCK_STATE]: prints the path of a root as the image build leaves it.
mkroot() {
    r=$T/$1
    mkdir -p "$r/usr/share/apex" "$r/usr/share/gnome-shell/extensions" \
        "$r/usr/share/glib-2.0/schemas" "$r/usr/lib/systemd/user" "$r/usr/share/doc/glib2" \
        "$r/usr/lib64" "$r/etc/environment.d"
    write_lane_lock "$r/usr/share/apex/rpms.lock" "${2:-built}"
    # A resource stores each sheet uncompressed between binary headers.
    printf 'GVariant\000\000\000\000/*! apex-shell-theme light */\n.apex-theme-marker {\n  color: #16161a; }\n\000\000/*! apex-shell-theme dark */\n\000/*! apex-shell-structure */\n\000' \
        >"$r/usr/share/gnome-shell/gnome-shell-theme.gresource"
    cp "$DESKTOP"/schemas/*.gschema.xml "$DESKTOP"/schemas/*.gschema.override "$r/usr/share/glib-2.0/schemas/"
    upstream_schemas "$r/usr/share/glib-2.0/schemas" "$DESKTOP/schemas/90_apex.gschema.override"
    printf '<schemalist><schema id="org.gnome.Ptyxis.Profile"><key name="label" type="s"><default>%s</default></key><key name="palette" type="s"><default>%s</default></key><key name="cell-height-scale" type="d"><range min="1.0" max="2.0"/><default>1.0</default></key></schema></schemalist>\n' \
        "''" "'gnome'" >"$r/usr/share/glib-2.0/schemas/org.gnome.Ptyxis.Profile.gschema.xml"
    # Fedora's dconf profile and an empty locks directory, as the dconf package ships them.
    mkdir -p "$r/etc/dconf/profile" "$r/etc/dconf/db/distro.d/locks"
    printf 'user-db:user\nsystem-db:local\nsystem-db:site\nsystem-db:distro\n' >"$r/etc/dconf/profile/user"
    cp "$DESKTOP"/dconf/distro.d/* "$r/etc/dconf/db/distro.d/"
    touch -d '2026-10-01 00:00' "$r"/etc/dconf/db/distro.d/*
    : >"$r/etc/dconf/db/distro"
    cp -R "$DESKTOP/systemd/user/." "$r/usr/lib/systemd/user/"
    printf '[Unit]\nDescription=GNOME Shell\nOnFailure=org.gnome.Shell-disable-extensions.service\n\n[Service]\nType=notify\nExecStart=/usr/bin/true\nSuccessExitStatus=1\n' \
        >"$r/usr/lib/systemd/user/org.gnome.Shell@.service"
    printf '[Unit]\nDescription=Disable GNOME Shell extensions after failure\nDefaultDependencies=no\n\n[Service]\nType=simple\nExecStart=/usr/bin/true\n' \
        >"$r/usr/lib/systemd/user/org.gnome.Shell-disable-extensions.service"
    mkdir -p "$r/etc/profile.d"
    cp "$DESKTOP/ptyxis/apex-prompt.sh" "$r/etc/profile.d/"
    : >"$r/etc/profile.d/vte.sh"
    # GLib's NEWS names G_RESOURCE_OVERLAYS, and libgio reads it: neither sets it.
    printf 'Overview of changes in GLib 2.51.1\n* Add G_RESOURCE_OVERLAYS\n' >"$r/usr/share/doc/glib2/NEWS"
    printf '\177ELF\002\001\001\000\000G_RESOURCE_OVERLAYS\000' >"$r/usr/lib64/libgio-2.0.so.0"
    rpmdb "$T/$1.db"
    printf '%s\n' "$r"
}

desktop() {
    run env PATH="$(fake_path)" FAKE_RPMDB="$T/$1.db" ROOT="$T/$1" "$SH" "$CHECKS/desktop.sh"
}

r=$(mkroot good)
desktop good
expect_rc "the Apex shell as the lane built it passes" 0
expect_out "every locked RPM at its NEVRA" '^PASS desktop: the 4 locked RPM\(s\) are installed at their locked NEVRAs$'
expect_out "gnome-shell is an Apex build" '^PASS desktop: gnome-shell 51\.0-1\.fc45\.apex1 is an Apex build \(the family is built\)$'
for p in gnome-shell gnome-shell-common; do
    expect_out "$p carries the Apex RPM signature" "^PASS desktop: $p carries the Apex RPM signature \\(8DA3252BD6EF25FA\\)\$"
done
expect_out "the mutter pin" '^PASS desktop: gnome-shell requires mutter = 0:51\.0-1\.fc45, the installed mutter$'
expect_out "mutter is Fedora-signed" '^PASS desktop: mutter 0:51\.0-1\.fc45 carries Fedora.s signature$'
expect_out "Ptyxis before its family" '^PASS desktop: ptyxis 51\.0-1\.fc45 is Fedora.s build, signed by Fedora.s key \(the lane has no ptyxis family\)$'
expect_out "the Apex prompt" '^PASS desktop: /etc/profile.d/apex-prompt.sh is apex-desktop.s and sorts before vte.sh'
for v in 'apex-shell-theme light' 'apex-shell-theme dark' 'apex-shell-structure'; do
    expect_out "the theme carries /*! $v */" "^PASS desktop: .*gnome-shell-theme\\.gresource carries /\\*! $v \\*/\$"
done
expect_out "the stock sheets are left to the lane and G2" '^SKIP desktop: upstream.s sheets under /org/gnome/shell/theme/stock/'
expect_out "rpm -V is clean" '^PASS desktop: rpm -V gnome-shell gnome-shell-common is clean'
expect_out "an empty extensions directory" '^PASS desktop: no shell extension'
expect_out "documentation and binaries do not count" '^PASS desktop: no text file under /usr or /etc names G_RESOURCE_OVERLAYS,--unsafe-mode,APEX_SHELL_TEST_FAULT \(1 documentation file\(s\) not counted\)$'
expect_out "the committed schema compiles with --strict" '^PASS desktop: the Apex schema compiles with --strict$'
expect_out "the schema has the Spotlight binding" '^PASS desktop: the Apex schema has toggle-spotlight$'
expect_out "the committed override compiles with --strict" '^PASS desktop: /usr/share/glib-2\.0/schemas/90_apex\.gschema\.override sets no color-scheme and compiles with --strict against the installed schemas$'
expect_out "the dconf profile reads the distro database" '^PASS desktop: /etc/dconf/profile/user lists system-db:distro$'
expect_out "the distro database is compiled" '^PASS desktop: /etc/dconf/db/distro is compiled from every file in /etc/dconf/db/distro\.d$'
expect_out "an empty locks directory holds no lock" '^PASS desktop: no dconf lock in /etc/dconf/db/distro\.d$'
expect_out "the Ptyxis profile is the default and valid" "^PASS desktop: the $NKEYS dconf default\\(s\\) in /etc/dconf/db/distro\\.d set Ptyxis's default profile [0-9a-f]{32}, and each is a valid setting$"
expect_out "the committed crash guard verifies" '^PASS desktop: the crash guard is installed'

r=$(mkroot held held)
desktop held
expect_rc "a held family (the last good build) passes" 0
expect_out "and says so" '^PASS desktop: gnome-shell 51\.0-1\.fc45\.apex1 is an Apex build \(the family is held\)$'

r=$(mkroot nolock)
rm "$r/usr/share/apex/rpms.lock"
desktop nolock
expect_rc "an image without the lane's lock fails" 1
expect_out "and says where it belongs" '^FAIL desktop: no /usr/share/apex/rpms\.lock'
r=$(mkroot nofamily)
printf '# apex rpms.lock 1: x\n' >"$r/usr/share/apex/rpms.lock"
desktop nofamily
expect_rc "a lock without a gnome-shell family fails" 1
expect_out "and says so" '^FAIL desktop: /usr/share/apex/rpms\.lock has no gnome-shell family'
r=$(mkroot unknownstate)
sed -i 's/^family gnome-shell built /family gnome-shell pending /' "$r/usr/share/apex/rpms.lock"
desktop unknownstate
expect_rc "a gnome-shell family in an unknown state fails (no shell check is skipped silently)" 1
expect_out "and names the state" "^FAIL desktop: the lane's gnome-shell family is in the unknown state 'pending'"

r=$(mkroot fedorashell)
rpmdb "$T/fedorashell.db" gnome-shell.evr=51.0-1.fc45 'gnome-shell.requires=["mutter(x86-64) >= 51.0"]'
desktop fedorashell
expect_rc "Fedora's gnome-shell under a built lock fails" 1
expect_out "names the locked NEVRA" '^FAIL desktop: gnome-shell: installed gnome-shell-0:51\.0-1\.fc45\.x86_64, but the lane locked gnome-shell-0:51\.0-1\.fc45\.apex1\.x86_64$'
expect_out "and the release" '^FAIL desktop: gnome-shell 51\.0-1\.fc45 is not an \.apexN build'
expect_out "and the missing pin" '^FAIL desktop: gnome-shell has no Requires: mutter\(x86-64\) = EVR'

r=$(mkroot pinonly)
sed -i 's/51\.0-1\.fc45\.apex1/51.0-1.fc45.apex1.2/g' "$r/usr/share/apex/rpms.lock"
rpmdb "$T/pinonly.db" gnome-shell.evr=51.0-1.fc45.apex1.2 gnome-shell-common.evr=51.0-1.fc45.apex1.2
desktop pinonly
expect_rc "an .apexN.M build passes" 0

r=$(mkroot mutter)
sed -i 's/mutter-0:51\.0-1\.fc45/mutter-0:51.0-2.fc45/; s/mutter-51\.0-1\.fc45/mutter-51.0-2.fc45/' "$r/usr/share/apex/rpms.lock"
rpmdb "$T/mutter.db" mutter.evr=51.0-2.fc45
desktop mutter
expect_rc "a mutter other than the pin fails" 1
expect_out "and names both" '^FAIL desktop: gnome-shell requires mutter = 0:51\.0-1\.fc45, but mutter 0:51\.0-2\.fc45$'
r=$(mkroot unsigned)
rpmdb "$T/unsigned.db" 'mutter.signature=(none)' 'mutter-common.signature=RSA/SHA256, Key ID 0123456789abcdef'
desktop unsigned
expect_rc "a mutter without Fedora's signature fails" 1
expect_out "unsigned" '^FAIL desktop: mutter is not signed by Fedora.s key'
expect_out "another key" '^FAIL desktop: mutter-common is not signed by Fedora.s key'

r=$(mkroot apexunsigned)
rpmdb "$T/apexunsigned.db" 'gnome-shell.signature=(none)' 'gnome-shell-common.signature=RSA/SHA256, Key ID 655a4b02f577861e'
desktop apexunsigned
expect_rc "a locked Apex shell without the Apex signature fails" 1
expect_out "unsigned" '^FAIL desktop: gnome-shell is not signed by the Apex RPM key \(8DA3252BD6EF25FA\)$'
expect_out "Fedora's key instead" '^FAIL desktop: gnome-shell-common is not signed by the Apex RPM key'

r=$(mkroot nodark)
printf 'GVariant\000/*! apex-shell-theme light */\n\000/*! apex-shell-structure */\n' >"$r/usr/share/gnome-shell/gnome-shell-theme.gresource"
desktop nodark
expect_rc "a theme without the dark marker fails" 1
expect_out "and names it" '^FAIL desktop: .*lacks /\*! apex-shell-theme dark \*/'

r=$(mkroot modified)
rpmdb "$T/modified.db" 'gnome-shell.modified=["/usr/share/gnome-shell/gnome-shell-theme.gresource"]'
desktop modified
expect_rc "a modified gnome-shell file fails" 1
expect_out "rpm -V shows it" '^FAIL desktop: rpm -V gnome-shell gnome-shell-common \(exit 1\): S\.5\.\.\.\.\.\. +/usr/share/gnome-shell/gnome-shell-theme\.gresource'

r=$(mkroot extension)
mkdir "$r/usr/share/gnome-shell/extensions/dash-to-dock@micxgx.gmail.com"
desktop extension
expect_rc "a shell extension fails" 1
expect_out "and names it" '^FAIL desktop: shell extensions ship .*dash-to-dock@micxgx\.gmail\.com'

bad_setting() {
    r=$(mkroot "$1")
    mkdir -p "$(dirname -- "$r/$2")"
    printf '%s\n' "$3" >"$r/$2"
    desktop "$1"
    expect_rc "fails: $4" 1
    expect_out "and names $2" "^FAIL desktop: /$2 names "
}
bad_setting overlays etc/environment.d/90-dev.conf 'G_RESOURCE_OVERLAYS=/org/gnome/shell/ui=/var/tmp/ui' \
    "G_RESOURCE_OVERLAYS in environment.d"
bad_setting unsafe 'usr/lib/systemd/user/org.gnome.Shell@.service.d/60-dev.conf' \
    "$(printf '[Service]\nExecStart=\nExecStart=/usr/bin/true --unsafe-mode')" "--unsafe-mode in a unit drop-in"
bad_setting fault usr/lib/environment.d/50-test.conf 'APEX_SHELL_TEST_FAULT=abort-after-enable' \
    "APEX_SHELL_TEST_FAULT in the user environment"
bad_setting profile etc/profile.d/test.sh 'export APEX_SHELL_TEST_FAULT=enable' "APEX_SHELL_TEST_FAULT in a profile script"
# Without /etc, grep exits 2 whoever runs the test.
r=$(mkroot unsearched)
rm -rf "${r:?}/etc"
desktop unsearched
expect_rc "a scan with grep errors fails" 1
expect_out "and says so" '^FAIL desktop: grep could not search every file under /usr and /etc \(exit 2\)'
expect_no_out "with no pass line for the scan" '^PASS desktop: no text file under /usr or /etc'

r=$(mkroot noschema)
rm "$r"/usr/share/glib-2.0/schemas/*.gschema.xml
desktop noschema
expect_rc "a missing Apex schema fails" 1
expect_out "and says what that means" '^FAIL desktop: no /usr/share/glib-2\.0/schemas/io\.github\.apex_linux\.Apex\.Desktop\.gschema\.xml: the layer would run in safe mode'
r=$(mkroot badschema)
sed -i 's|<default>true</default>|<default>yes</default>|' "$r"/usr/share/glib-2.0/schemas/io.github.apex_linux.Apex.Desktop.gschema.xml
desktop badschema
expect_rc "a schema that fails --strict fails" 1
expect_out "and says so" '^FAIL desktop: the Apex schema fails --strict'

OVR=usr/share/glib-2.0/schemas/90_apex.gschema.override
r=$(mkroot nooverride)
rm "$r/$OVR"
desktop nooverride
expect_rc "a missing override fails" 1
expect_out "and says so" '^FAIL desktop: no /usr/share/glib-2\.0/schemas/90_apex\.gschema\.override: the vendor defaults are missing'
r=$(mkroot colorscheme)
printf "\n[org.gnome.desktop.interface]\ncolor-scheme='prefer-dark'\n" >>"$r/$OVR"
desktop colorscheme
expect_rc "an override that sets color-scheme fails" 1
expect_out "and says why" '^FAIL desktop: .*90_apex\.gschema\.override sets color-scheme'
r=$(mkroot unknownkey)
printf '\n[org.gnome.desktop.interface]\nno-such-key=true\n' >>"$r/$OVR"
desktop unknownkey
expect_rc "an override with a key no schema has fails" 1
expect_out "glib-compile-schemas names it" '^FAIL desktop: .*90_apex\.gschema\.override fails --strict: .*no-such-key'
r=$(mkroot badupstream)
printf '<schemalist><schema id="org.example.Broken"><key name="k" type="b"><default>yes</default></key></schema></schemalist>\n' \
    >"$r/usr/share/glib-2.0/schemas/org.example.Broken.gschema.xml"
desktop badupstream
expect_rc "an upstream schema that fails --strict leaves the override unvalidated, with a warning" 0
expect_out "and says so" '^WARN desktop: the installed schemas fail --strict without the Apex override'
expect_no_out "with no pass line for the override" '^PASS desktop: .*90_apex\.gschema\.override'

DISTRO=etc/dconf/db/distro.d
KEYFILE=$DISTRO/50-apex-ptyxis
r=$(mkroot nodistrodb)
sed -i '/^system-db:distro$/d' "$r/etc/dconf/profile/user"
desktop nodistrodb
expect_rc "a dconf profile without system-db:distro fails" 1
expect_out "and says what that loses" '^FAIL desktop: /etc/dconf/profile/user does not list system-db:distro: the Apex Ptyxis profile is never read$'
r=$(mkroot nodb)
rm "$r/etc/dconf/db/distro"
desktop nodb
expect_rc "an image without the compiled distro database fails" 1
expect_out "and names dconf update" '^FAIL desktop: no /etc/dconf/db/distro: the image build did not run dconf update$'
r=$(mkroot staledb)
touch -d '2026-09-01 00:00' "$r/etc/dconf/db/distro"
desktop staledb
expect_rc "a database older than its keyfiles fails" 1
expect_out "and says so" '^FAIL desktop: /etc/dconf/db/distro is older than a file in /etc/dconf/db/distro\.d'
r=$(mkroot lock)
printf '/org/gnome/Ptyxis/default-profile-uuid\n' >"$r/$DISTRO/locks/50-apex"
desktop lock
expect_rc "a dconf lock fails" 1
expect_out "and names it" '^FAIL desktop: dconf locks ship in /etc/dconf/db/distro\.d/locks \(ADR 0011 refuses them\): /etc/dconf/db/distro\.d/locks/50-apex$'
r=$(mkroot unknownprofilekey)
printf 'no-such-key=true\n' >>"$r/$KEYFILE"
desktop unknownprofilekey
expect_rc "a profile key Ptyxis does not have fails" 1
expect_out "and names it" '^FAIL desktop: /etc/dconf/db/distro\.d/50-apex-ptyxis \[org/gnome/Ptyxis/Profiles/[0-9a-f]{32}\] no-such-key=true is not a valid org\.gnome\.Ptyxis\.Profile setting'
r=$(mkroot badvalue)
sed -i 's/^cell-height-scale=.*/cell-height-scale=3.0/' "$r/$KEYFILE"
desktop badvalue
expect_rc "a value outside the key's range fails" 1
expect_out "and names it" '^FAIL desktop: .*\] cell-height-scale=3\.0 is not a valid org\.gnome\.Ptyxis\.Profile setting'
# A schema that takes a type from an enums file, as upstream's do: without the file
# glib-compile-schemas skips the schema and still exits 0.
r=$(mkroot enums)
printf '<schemalist><enum id="org.gnome.Ptyxis.CursorShape"><value nick="block" value="0"/><value nick="beam" value="1"/></enum></schemalist>\n' \
    >"$r/usr/share/glib-2.0/schemas/org.gnome.Ptyxis.enums.xml"
sed -i "s|</schema>|<key name=\"cursor-shape\" enum=\"org.gnome.Ptyxis.CursorShape\"><default>'block'</default></key></schema>|" \
    "$r/usr/share/glib-2.0/schemas/org.gnome.Ptyxis.Profile.gschema.xml"
printf "cursor-shape='beam'\n" >>"$r/$KEYFILE"
touch -d '2026-10-01 00:00' "$r/$KEYFILE"
desktop enums
expect_rc "schemas whose types come from an enums file pass" 0
expect_out "the override is validated against them" '^PASS desktop: /usr/share/glib-2\.0/schemas/90_apex\.gschema\.override sets no color-scheme and compiles with --strict against the installed schemas$'
expect_out "the profile key of the enum type is a valid setting" "^PASS desktop: the $((NKEYS + 1)) dconf default\\(s\\) in /etc/dconf/db/distro\\.d set Ptyxis's default profile"
r=$(mkroot fixedpath)
printf "[org/gnome/desktop/interface]\nfont-hinting='none'\n" >"$r/$DISTRO/60-fixed"
desktop fixedpath
expect_rc "a fixed-path key in dconf fails" 1
expect_out "and points at the override" '^FAIL desktop: /etc/dconf/db/distro\.d/60-fixed \[org/gnome/desktop/interface\] font-hinting: only the Ptyxis profile belongs in dconf; a fixed-path key goes in /usr/share/glib-2\.0/schemas/90_apex\.gschema\.override$'
r=$(mkroot otherprofile)
sed -i 's|^\[org/gnome/Ptyxis/Profiles/.*\]$|[org/gnome/Ptyxis/Profiles/00000000000000000000000000000000]|' "$r/$KEYFILE"
desktop otherprofile
expect_rc "a profile that is not the default fails" 1
expect_out "and says so" "^FAIL desktop: .*profile 0{32} is not Ptyxis's default-profile-uuid and in profile-uuids"
r=$(mkroot noprofile)
rm "$r/$KEYFILE"
desktop noprofile
expect_rc "an image without the Apex Ptyxis profile fails" 1
expect_out "and says so" '^FAIL desktop: no key in /etc/dconf/db/distro\.d: the Apex Ptyxis profile is missing'
# CI runs this file in fedora:45 with dconf installed: Fedora's own files must pass.
if [ -f /etc/dconf/profile/user ] && grep -qx 'ID=fedora' /etc/os-release 2>/dev/null; then
    r=$(mkroot fedoradconf)
    cp /etc/dconf/profile/user "$r/etc/dconf/profile/user"
    rm -rf "${r:?}/$DISTRO/locks"
    if [ -d /etc/dconf/db/distro.d/locks ]; then cp -R /etc/dconf/db/distro.d/locks "$r/$DISTRO/"; fi
    desktop fedoradconf
    expect_rc "Fedora's dconf profile and distro locks directory pass" 0
fi

r=$(mkroot noguard)
rm "$r/usr/lib/systemd/user/org.gnome.Shell@.service.d/50-apex.conf"
desktop noguard
expect_rc "a missing drop-in fails" 1
expect_out "and says so" '^FAIL desktop: the crash guard is not installed'
r=$(mkroot noonfailure)
sed -i 's/^OnFailure=.*/OnFailure=gnome-session-shutdown.target/' "$r/usr/lib/systemd/user/org.gnome.Shell@.service.d/50-apex.conf"
desktop noonfailure
expect_rc "a drop-in without the OnFailure= fails" 1
r=$(mkroot ungated)
sed -i '/^ConditionPathExists=/d' "$r/usr/lib/systemd/user/apex-shell-safe.service"
desktop ungated
expect_rc "a guard that is not gated on the layer's marker fails" 1
expect_out "and says so" 'is not gated on the layer.s marker'
r=$(mkroot unordered)
sed -i '/^Before=gnome-session-restart-dbus\.service$/d' "$r/usr/lib/systemd/user/apex-shell-safe.service"
desktop unordered
expect_rc "a guard not ordered before the session bus restart fails" 1
expect_out "and says so" 'is not ordered before gnome-session-restart-dbus\.service'
r=$(mkroot badunit)
sed -i 's/^Type=oneshot$/Type=oneshot\nRestartSec=soon/' "$r/usr/lib/systemd/user/apex-shell-safe.service"
desktop badunit
expect_rc "a guard unit that does not verify fails" 1
expect_out "systemd-analyze names it" '^FAIL desktop: systemd-analyze --user verify'

r=$(mkroot stock stock)
printf 'GVariant\000stage { color: #fff; }\n' >"$r/usr/share/gnome-shell/gnome-shell-theme.gresource"
fedora='RSA/SHA256, Mon Sep 14 2026, Key ID 655a4b02f577861e'
rpmdb "$T/stock.db" gnome-shell.evr=51.0-1.fc45 gnome-shell-common.evr=51.0-1.fc45 \
    "gnome-shell.signature=$fedora" "gnome-shell-common.signature=$fedora" \
    'gnome-shell.requires=["mutter(x86-64) >= 51.0"]'
desktop stock
expect_rc "Fedora's signed shell under a stock family passes" 0
expect_out "and is named" '^PASS desktop: gnome-shell 51\.0-1\.fc45 is Fedora.s build, signed by Fedora.s key \(the family is stock: degraded=shell\)$'
expect_out "with a stock theme" '^PASS desktop: no Apex marker in the theme'
r=$(mkroot stockapex stock)
desktop stockapex
expect_rc "an Apex shell under a stock family fails" 1
expect_out "and says so" '^FAIL desktop: gnome-shell 51\.0-1\.fc45\.apex1 is an Apex build, but the lane.s gnome-shell family is stock$'

r=$(mkroot noprompt)
rm "$r/etc/profile.d/apex-prompt.sh"
desktop noprompt
expect_rc "an image without the Apex prompt fails" 1
expect_out "and says so" '^FAIL desktop: no /etc/profile.d/apex-prompt.sh'
r=$(mkroot strayprompt)
rpmdb "$T/strayprompt.db" 'apex-desktop.files=[]'
desktop strayprompt
expect_rc "a prompt file no package owns fails" 1
expect_out "and says so" "^FAIL desktop: /etc/profile.d/apex-prompt.sh belongs to 'no package', not apex-desktop$"

apex='EdDSA/SHA512, Tue Sep 29 2026 07:00:00 AM UTC, Key ID 8da3252bd6ef25fa'
r=$(mkroot ptyxisbuilt)
add_ptyxis "$r/usr/share/apex/rpms.lock" built
rpmdb "$T/ptyxisbuilt.db" ptyxis.evr=51.0-1.fc45.apex1 "ptyxis.signature=$apex"
mkdir -p "$r/usr/bin"
printf '\177ELF\002\001\001\000\000/*! apex-ptyxis */\000' >"$r/usr/bin/ptyxis"
desktop ptyxisbuilt
expect_rc "the Apex terminal as the lane built it passes" 0
expect_out "with every locked RPM" '^PASS desktop: the 5 locked RPM\(s\) are installed at their locked NEVRAs$'
expect_out "and is named" '^PASS desktop: ptyxis 51\.0-1\.fc45\.apex1 is an Apex build with the Apex RPM signature \(the family is built\)$'
expect_out "with the Apex resource" '^PASS desktop: /usr/bin/ptyxis carries /\*! apex-ptyxis \*/: the Apex resource is compiled in$'
r=$(mkroot ptyxisnomarker)
add_ptyxis "$r/usr/share/apex/rpms.lock" built
rpmdb "$T/ptyxisnomarker.db" ptyxis.evr=51.0-1.fc45.apex1 "ptyxis.signature=$apex"
desktop ptyxisnomarker
expect_rc "an Apex Ptyxis without the Apex resource fails" 1
expect_out "and says so" '^FAIL desktop: /usr/bin/ptyxis lacks /\*! apex-ptyxis \*/'
r=$(mkroot ptyxisstockmarker)
add_ptyxis "$r/usr/share/apex/rpms.lock" stock
mkdir -p "$r/usr/bin"
printf '\177ELF/*! apex-ptyxis */\000' >"$r/usr/bin/ptyxis"
desktop ptyxisstockmarker
expect_rc "the Apex resource under a stock family fails" 1
expect_out "and says so" '^FAIL desktop: /usr/bin/ptyxis carries /\*! apex-ptyxis \*/, but the family is stock$'
r=$(mkroot ptyxisfedora)
add_ptyxis "$r/usr/share/apex/rpms.lock" held
desktop ptyxisfedora
expect_rc "Fedora's Ptyxis under a held family fails" 1
expect_out "and says so" '^FAIL desktop: ptyxis 51\.0-1\.fc45 is not an \.apexN build, but the lane.s ptyxis family is held$'
r=$(mkroot ptyxisstock)
add_ptyxis "$r/usr/share/apex/rpms.lock" stock
desktop ptyxisstock
expect_rc "Fedora's Ptyxis under a stock family passes" 0
expect_out "and is named" '^PASS desktop: ptyxis 51\.0-1\.fc45 is Fedora.s build, signed by Fedora.s key \(the family is stock: degraded=terminal\)$'
r=$(mkroot ptyxisstray)
rpmdb "$T/ptyxisstray.db" ptyxis.evr=51.0-1.fc45.apex1 "ptyxis.signature=$apex"
desktop ptyxisstray
expect_rc "an Apex Ptyxis the lane did not lock fails" 1
expect_out "and says so" '^FAIL desktop: ptyxis 51\.0-1\.fc45\.apex1 is an Apex build, but the lane has no ptyxis family$'
r=$(mkroot noptyxis)
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); del d["ptyxis"]; json.dump(d, open(sys.argv[1], "w"))' "$T/noptyxis.db"
desktop noptyxis
expect_rc "an image without Ptyxis fails" 1
expect_out "and says so" '^FAIL desktop: ptyxis is not installed'

done_testing
