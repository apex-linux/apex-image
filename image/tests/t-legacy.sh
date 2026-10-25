#!/bin/sh
# image/checks/legacy.sh against a fake rpmdb that, like rpm headers, keeps gtk3's
# requirements of the libgtk-3 it provides itself.
. "$(dirname -- "$0")/lib.sh"

GTK3_LIBS='"libgtk-3.so.0()(64bit)", "libgdk-3.so.0()(64bit)"'

# write_db FILE EXTRA_JSON: every allowlisted package, Xwayland, plus EXTRA_JSON entries.
write_db() {
    cat >"$1" <<EOF
{
  "rpm": {},
  "gnome-shell": {"requires": ["xdg-desktop-portal-gtk", "libecal-2.0.so.3()(64bit)"]},
  "gtk3": {"evr": "3.24.52-6.fc45",
           "requires": [$GTK3_LIBS, "libX11.so.6()(64bit)"],
           "provides": ["gtk3(x86-64)", $GTK3_LIBS],
           "files": ["/usr/lib64/libgtk-3.so.0"]},
  "xdg-desktop-portal-gtk": {"requires": [$GTK3_LIBS]},
  "xdg-user-dirs-gtk": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "evolution-data-server": {"requires": ["libgtk-3.so.0()(64bit)"],
                            "provides": ["libecal-2.0.so.3()(64bit)"]},
  "webkit2gtk4.1": {"requires": [$GTK3_LIBS]},
  "libcanberra-gtk3": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "gnome-desktop3": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "gnome-autoar": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "ibus": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "ibus-gtk3": {"requires": ["gtk3(x86-64)", "libgtk-3.so.0()(64bit)"]},
  "gnome-disk-utility": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "libhandy": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "gstreamer1-plugins-bad-free": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "libdecor": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "vte291": {"requires": ["libgtk-3.so.0()(64bit)"]},
  "xorg-x11-server-Xwayland": {"requires": ["libdecor-0.so.0()(64bit)"]},
  "xorg-x11-xinit": {}, "xorg-x11-xauth": {}, "xhost": {}, "xmodmap": {},
  "xrdb": {}, "setxkbmap": {}$2
}
EOF
}

legacy() {
    run env PATH="$(fake_path)" FAKE_RPMDB="$1" ROOT="$T/root" \
        LEGACY_ALLOWLIST="${2:-$IMAGE_DIR/audit/legacy-allowlist.txt}" "$SH" "$CHECKS/legacy.sh"
}

mkdir -p "$T/root"

write_db "$T/db.json" ''
legacy "$T/db.json"
expect_rc "committed allowlist passes on the GNOME 51 set" 0
expect_out "gtk3 is flagged as the GTK3 provider and allowlisted" \
    '^PASS legacy: allowlisted until F46: gtk3 \(.*provides libgtk-3\.so\.0\(\)\(64bit\)'
expect_no_out "gtk3's self-requirement is not counted as a consumer" \
    ': gtk3 \(.*requires libgtk-3'
expect_out "ibus-gtk3 is flagged for requiring gtk3(x86-64)" \
    'allowlisted until F46: ibus-gtk3 \(.*requires gtk3\(x86-64\)'
expect_no_out "Xwayland is not flagged" 'xorg-x11-server-Xwayland'
expect_no_out "no stale entries" '^WARN'

grep -v '^gtk3	' "$IMAGE_DIR/audit/legacy-allowlist.txt" >"$T/allow-no-gtk3"
legacy "$T/db.json" "$T/allow-no-gtk3"
expect_rc "an allowlist without gtk3 fails" 1
expect_out "and names gtk3 as the provider" '^FAIL legacy: not allowlisted: gtk3 \(provides '

write_db "$T/db-tour.json" ',
  "gnome-tour": {}'
legacy "$T/db-tour.json"
expect_rc "an installed gnome-tour fails the gate (dropped from the app set)" 1
expect_out "named as banned" '^FAIL legacy: not allowlisted: gnome-tour \(banned by name\)$'

write_db "$T/db-gtk2.json" ',
  "gtk2": {"provides": ["gtk2(x86-64)", "libgtk-x11-2.0.so.0()(64bit)", "libgdk-x11-2.0.so.0()(64bit)"],
           "requires": ["libgtk-x11-2.0.so.0()(64bit)"]},
  "leafpad": {"requires": ["libgtk-x11-2.0.so.0()(64bit)", "libgdk-x11-2.0.so.0()(64bit)"]}'
legacy "$T/db-gtk2.json"
expect_rc "a GTK2 consumer fails the gate" 1
expect_out "the consumer is named" '^FAIL legacy: not allowlisted: leafpad \(requires libgdk-x11-2\.0'
expect_out "gtk2 is named as the provider" '^FAIL legacy: not allowlisted: gtk2 \(provides '
expect_no_out "gtk2's self-requirement is not counted" ': gtk2 \(.*requires libgtk-x11'

write_db "$T/db-fork.json" ',
  "gtk3-fork": {"provides": ["libgtk-3.so.0()(64bit)"], "requires": ["libgtk-3.so.0()(64bit)"]}'
legacy "$T/db-fork.json"
expect_rc "a second GTK3 provider fails" 1
expect_out "and is named" '^FAIL legacy: not allowlisted: gtk3-fork \(provides libgtk-3'

write_db "$T/db-xorg.json" ',
  "xorg-x11-server-Xorg": {"provides": ["Xorg", "xserver-abi(videodrv-28)"],
                           "files": ["/usr/libexec/Xorg"], "requires": ["/usr/libexec/Xorg"]},
  "xorg-x11-drv-libinput": {"requires": ["xserver-abi(xinput-26)"]}'
legacy "$T/db-xorg.json"
expect_rc "the Xorg server fails" 1
expect_out "Xorg is named as provider and banned" \
    '^FAIL legacy: not allowlisted: xorg-x11-server-Xorg \(banned by name;provides '
expect_no_out "Xorg's own file requirement is not a consumer" 'requires /usr/libexec/Xorg'
expect_out "an X driver is flagged" '^FAIL legacy: not allowlisted: xorg-x11-drv-libinput '

write_db "$T/db-module.json" ',
  "tigervnc-server-module": {"requires": ["libc.so.6()(64bit)", "xserver-abi(videodrv-28)"]}'
legacy "$T/db-module.json"
expect_rc "an X server module with several requirements fails the gate" 1
expect_out "and is named by its ABI requirement" \
    '^FAIL legacy: not allowlisted: tigervnc-server-module \(requires xserver-abi\(videodrv-28\)'
expect_no_out "rpm reports no query format error" 'array iterator'

done_testing
