#!/bin/sh
# image/checks/desktop.sh on fake roots with the committed schema and crash guard units.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found (the fake rpm)"
command -v glib-compile-schemas >/dev/null 2>&1 || skip_all "glib-compile-schemas not found"
command -v systemd-analyze >/dev/null 2>&1 || skip_all "systemd-analyze not found"
[ -x /usr/bin/gsettings ] || skip_all "no /usr/bin/gsettings (systemd-analyze checks apex-shell-safe.service's ExecStart)"

DESKTOP=$REPO_ROOT/desktop
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

# rpmdb FILE [NAME.FIELD=VALUE...]: each edit sets one field, as JSON when it starts
# with [ or ".
rpmdb() {
    python3 - "$@" <<'PY'
import json, sys
fedora = "RSA/SHA256, Mon Sep 14 2026 10:00:00 AM UTC, Key ID 655a4b02f577861e"
apex = "EdDSA/SHA512, Tue Sep 29 2026 07:00:00 AM UTC, Key ID abef111d1fcf882b"
theme = "/usr/share/gnome-shell/gnome-shell-theme.gresource"
db = {
    "gnome-shell": {"evr": "51.0-1.fc45.apex1", "files": [theme], "signature": apex,
                    "requires": ["mutter(x86-64) >= 51.0", "mutter(x86-64) = 51.0-1.fc45"]},
    "gnome-shell-common": {"evr": "51.0-1.fc45.apex1", "arch": "noarch", "signature": apex},
    "mutter": {"evr": "51.0-1.fc45", "signature": fedora},
    "mutter-common": {"evr": "51.0-1.fc45", "arch": "noarch", "signature": fedora},
}
for edit in sys.argv[2:]:
    key, value = edit.split("=", 1)
    name, field = key.rsplit(".", 1)
    db.setdefault(name, {})[field] = json.loads(value) if value[:1] in '["' else value
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(db, f)
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
    cp "$DESKTOP"/schemas/*.gschema.xml "$r/usr/share/glib-2.0/schemas/"
    cp -R "$DESKTOP/systemd/user/." "$r/usr/lib/systemd/user/"
    printf '[Unit]\nDescription=GNOME Shell\nOnFailure=org.gnome.Shell-disable-extensions.service\n\n[Service]\nType=notify\nExecStart=/usr/bin/true\nSuccessExitStatus=1\n' \
        >"$r/usr/lib/systemd/user/org.gnome.Shell@.service"
    printf '[Unit]\nDescription=Disable GNOME Shell extensions after failure\nDefaultDependencies=no\n\n[Service]\nType=simple\nExecStart=/usr/bin/true\n' \
        >"$r/usr/lib/systemd/user/org.gnome.Shell-disable-extensions.service"
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
    expect_out "$p carries the Apex RPM signature" "^PASS desktop: $p carries the Apex RPM signature \\(ABEF111D1FCF882B\\)\$"
done
expect_out "the mutter pin" '^PASS desktop: gnome-shell requires mutter = 0:51\.0-1\.fc45, the installed mutter$'
expect_out "mutter is Fedora-signed" '^PASS desktop: mutter 0:51\.0-1\.fc45 carries Fedora.s signature$'
for v in 'apex-shell-theme light' 'apex-shell-theme dark' 'apex-shell-structure'; do
    expect_out "the theme carries /*! $v */" "^PASS desktop: .*gnome-shell-theme\\.gresource carries /\\*! $v \\*/\$"
done
expect_out "the stock sheets are left to the lane and G2" '^SKIP desktop: upstream.s sheets under /org/gnome/shell/theme/stock/'
expect_out "rpm -V is clean" '^PASS desktop: rpm -V gnome-shell gnome-shell-common is clean'
expect_out "an empty extensions directory" '^PASS desktop: no shell extension'
expect_out "documentation and binaries do not count" '^PASS desktop: no text file under /usr or /etc names G_RESOURCE_OVERLAYS,--unsafe-mode,APEX_SHELL_TEST_FAULT \(1 documentation file\(s\) not counted\)$'
expect_out "the committed schema compiles with --strict" '^PASS desktop: the Apex schema compiles with --strict$'
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
expect_out "unsigned" '^FAIL desktop: gnome-shell is not signed by the Apex RPM key \(ABEF111D1FCF882B\)$'
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

done_testing
