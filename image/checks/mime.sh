#!/bin/sh
# The default apps the owner chose (answer 10), as gnome-session's gnome-mimeapps.list sets
# them: GLib resolves each type in ROOT alone, so an update that moves one fails here.
set -eu
CHECK_NAME=mime
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

# Builder claims text/x-python in that list and is not installed: text/plain's default takes it.
DEFAULTS='image/png org.gnome.Loupe.desktop
image/jpeg org.gnome.Loupe.desktop
video/mp4 org.gnome.Showtime.desktop
video/webm org.gnome.Showtime.desktop
audio/mpeg org.gnome.Decibels.desktop
audio/flac org.gnome.Decibels.desktop
application/pdf org.gnome.Papers.desktop
text/plain org.gnome.TextEditor.desktop
inode/directory org.gnome.Nautilus.desktop
text/html org.gnome.Epiphany.desktop
x-scheme-handler/https org.gnome.Epiphany.desktop
text/x-python org.gnome.TextEditor.desktop'

if ! gio=$(command -v gio); then
    fail "gio not found: the default apps cannot be resolved"
    finish
fi
make_tmpdir

default_for() {
    env -i PATH="$(rootpath /usr/bin)" HOME="$TMPD" LC_ALL=C XDG_CURRENT_DESKTOP=GNOME \
        XDG_DATA_HOME="$TMPD/data" XDG_CONFIG_HOME="$TMPD/config" XDG_CONFIG_DIRS="$(rootpath /etc/xdg)" \
        XDG_DATA_DIRS="$(rootpath /usr/share)" "$gio" mime "$1" 2>/dev/null |
        sed -n '1s/^Default application for .*: //p'
}

printf '%s\n' "$DEFAULTS" | while read -r type want; do
    got=$(default_for "$type")
    if [ "$got" = "$want" ]; then
        pass "$type opens $want"
    else
        fail "$type opens ${got:-no app}, not $want (gnome-session's gnome-mimeapps.list or the app set moved it)"
    fi
done >"$TMPD/rows"
cat "$TMPD/rows"
if grep -q '^FAIL ' "$TMPD/rows"; then
    _apex_failures=$((_apex_failures + $(grep -c '^FAIL ' "$TMPD/rows")))
fi
finish
