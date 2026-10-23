#!/bin/sh
# image/checks/keybindings.sh on stub GNOME schemas, and in fedora:45 on Fedora's own.
. "$(dirname -- "$0")/lib.sh"

command -v glib-compile-schemas >/dev/null 2>&1 || skip_all "glib-compile-schemas not found"
command -v gsettings >/dev/null 2>&1 || skip_all "gsettings not found"

DESKTOP=$APEX_DESKTOP_SRC/desktop
SCHEMAS=usr/share/glib-2.0/schemas

# stub ID KEY=VALUE...: a schema whose keys are 'as', as GNOME's keybinding keys are.
stub() {
    id=$1
    shift
    {
        printf '<schemalist><schema id="%s" path="/%s/">' "$id" "$(printf '%s' "$id" | tr . /)"
        for kv in "$@"; do
            printf '<key name="%s" type="as"><default><![CDATA[%s]]></default></key>' "${kv%%=*}" "${kv#*=}"
        done
        printf '</schema></schemalist>\n'
    } >"$r/$SCHEMAS/$id.gschema.xml"
}

# mkroot NAME: upstream's Super+Space input source, which the Apex override moves.
mkroot() {
    r=$T/$1
    mkdir -p "$r/$SCHEMAS"
    cp "$DESKTOP"/schemas/*.gschema.xml "$DESKTOP"/schemas/*.gschema.override "$r/$SCHEMAS/"
    stub org.gnome.desktop.wm.keybindings "switch-input-source=['<Super>space', 'XF86Keyboard']" \
        "switch-input-source-backward=['<Shift><Super>space', '<Shift>XF86Keyboard']" \
        "switch-applications=['<Super>Tab', '<Alt>Tab']" "activate-window-menu=['<Alt>space']"
    stub org.gnome.mutter.keybindings "toggle-tiled-left=['<Super>Left']" "toggle-tiled-right=['<Super>Right']"
    stub org.gnome.mutter.wayland.keybindings "restore-shortcuts=['<Super>Escape']"
    stub org.gnome.shell.keybindings "toggle-application-view=['<Super>a']" "toggle-quick-settings=['<Super>s']"
    stub org.gnome.settings-daemon.plugins.media-keys "screensaver=['<Super>l']" "custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']" \
        "volume-mute=@as []"
    printf '%s\n' "$r"
}

keybindings() {
    run env ROOT="$T/$1" "$SH" "$CHECKS/keybindings.sh"
}

r=$(mkroot good)
keybindings good
expect_rc "GNOME's stock bindings with the Apex override pass" 0
expect_out "and are counted" '^PASS keybindings: 14 default bindings across 6 schemas share no combination$'

r=$(mkroot nooverride)
rm "$r/$SCHEMAS/90_apex.gschema.override"
keybindings nooverride
expect_rc "without the override, Super+Space is both Spotlight and the input source" 1
expect_out "and both keys are named" '^FAIL keybindings: two default bindings share <super>space: io\.github\.apex_linux\.Apex\.Desktop\.Keybindings toggle-spotlight \(<Super>space\) and org\.gnome\.desktop\.wm\.keybindings switch-input-source \(<Super>space\)$'

r=$(mkroot planted)
stub org.gnome.shell.keybindings "toggle-application-view=['<Super>a']" "toggle-quick-settings=['<Mod4>left']"
keybindings planted
expect_rc "a planted duplicate in another spelling fails" 1
expect_out "and names both keys" '^FAIL keybindings: two default bindings share <super>left: org\.gnome\.mutter\.keybindings toggle-tiled-left \(<Super>Left\) and org\.gnome\.shell\.keybindings toggle-quick-settings \(<Mod4>left\)$'
expect_no_out "with no pass line" '^PASS keybindings: [0-9]+ default bindings'

r=$(mkroot reordered)
stub org.gnome.mutter.wayland.keybindings "restore-shortcuts=['<Primary><Shift>Escape']"
stub org.gnome.shell.keybindings "toggle-application-view=['<Super>a']" "toggle-quick-settings=['<Shift><Control>escape']"
keybindings reordered
expect_rc "modifiers in another order and an alias of Control still collide" 1
expect_out "and are named" '^FAIL keybindings: two default bindings share <control><shift>escape: '

r=$(mkroot samekey)
stub org.gnome.mutter.wayland.keybindings "restore-shortcuts=['<Super>Escape', '<Super>Escape']"
keybindings samekey
expect_rc "one key listing a combination twice is no conflict" 0

r=$(mkroot nomutter)
rm "$r/$SCHEMAS/org.gnome.mutter.keybindings.gschema.xml"
keybindings nomutter
expect_rc "a missing keybinding schema fails" 1
expect_out "and says its bindings were not checked" '^FAIL keybindings: no schema org\.gnome\.mutter\.keybindings under /usr/share/glib-2\.0/schemas: its bindings were not checked$'
expect_no_out "with no pass line" '^PASS keybindings: [0-9]+ default bindings'

# glib-compile-schemas skips a file it cannot parse and exits 0.
r=$(mkroot broken)
printf '<schemalist><schema id="org.gnome.shell.keybindings">\n' >"$r/$SCHEMAS/org.gnome.shell.keybindings.gschema.xml"
keybindings broken
expect_rc "a keybinding schema that does not parse fails" 1
expect_out "as a schema whose bindings were not checked" '^FAIL keybindings: no schema org\.gnome\.shell\.keybindings under '

# The schemas of the packages that ship keybindings, unpacked, not installed.
if grep -qx 'ID=fedora' /etc/os-release 2>/dev/null && command -v dnf5 >/dev/null 2>&1; then
    r=$T/fedora
    mkdir -p "$r/rpms" "$r/$SCHEMAS"
    run dnf5 -q download --repo=fedora --repo=updates --arch=x86_64 --arch=noarch --destdir="$r/rpms" \
        gsettings-desktop-schemas mutter-common gnome-shell-common gnome-settings-daemon
    expect_rc "dnf5 downloads Fedora's keybinding schema packages" 0
    for p in "$r"/rpms/*.rpm; do
        (cd "$r" && rpm2cpio "$p" | cpio -idm --quiet "./$SCHEMAS/*")
    done
    cp "$DESKTOP"/schemas/*.gschema.xml "$DESKTOP"/schemas/*.gschema.override "$r/$SCHEMAS/"
    run env ROOT="$r" "$SH" "$CHECKS/keybindings.sh"
    expect_true "the downloads hold Fedora's wm.keybindings schema" test -f "$r/$SCHEMAS/org.gnome.desktop.wm.keybindings.gschema.xml"
    sed -En 's/^(PASS|FAIL) keybindings: /# fedora: &/p' "$T/out"
    expect_rc "Fedora's stock keybindings with the Apex override share no combination" 0
fi

done_testing
