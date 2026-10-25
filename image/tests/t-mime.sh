#!/bin/sh
# image/checks/mime.sh: the default apps of answer 10 resolve in ROOT, as GLib resolves them.
. "$(dirname -- "$0")/lib.sh"

command -v gio >/dev/null 2>&1 || skip_all "gio not found"

APPS='org.gnome.Loupe loupe image/png;image/jpeg;
org.gnome.Showtime showtime video/mp4;video/webm;
org.gnome.Decibels decibels audio/mpeg;audio/flac;
org.gnome.Papers papers application/pdf;
org.gnome.TextEditor gnome-text-editor text/plain;
org.gnome.Nautilus nautilus inode/directory;
org.gnome.Epiphany epiphany text/html;x-scheme-handler/https;'

# mkroot NAME: the apps with their binaries, gnome-session's defaults and a subclass of text/plain.
mkroot() {
    r=$T/$1
    mkdir -p "$r/usr/bin" "$r/usr/share/applications" "$r/usr/share/mime" "$r/etc/xdg"
    printf '%s\n' "$APPS" | while read -r id bin types; do
        printf '#!/bin/sh\n' >"$r/usr/bin/$bin"
        chmod +x "$r/usr/bin/$bin"
        printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s %%U\nMimeType=%s\n' \
            "$id" "$bin" "$types" >"$r/usr/share/applications/$id.desktop"
    done
    cat >"$r/usr/share/applications/gnome-mimeapps.list" <<'LIST'
[Default Applications]
application/pdf=org.gnome.Papers.desktop
audio/mpeg=org.gnome.Decibels.desktop
image/jpeg=org.gnome.Loupe.desktop
image/png=org.gnome.Loupe.desktop
inode/directory=org.gnome.Nautilus.desktop
text/html=org.gnome.Epiphany.desktop
text/plain=org.gnome.TextEditor.desktop
text/x-python=org.gnome.Builder.desktop
video/mp4=org.gnome.Showtime.desktop
video/webm=org.gnome.Showtime.desktop
x-scheme-handler/https=org.gnome.Epiphany.desktop
LIST
    printf 'text/x-python text/plain\n' >"$r/usr/share/mime/subclasses"
    mimeinfo "$r"
    printf '%s\n' "$r"
}

# mimeinfo ROOT: update-desktop-database's mimeinfo.cache, where GLib finds each MimeType.
mimeinfo() {
    {
        printf '[MIME Cache]\n'
        for f in "$1"/usr/share/applications/*.desktop; do
            sed -n 's/^MimeType=//p' "$f" | tr ';' '\n' | sed '/^$/d' | sed "s|\$|=${f##*/};|"
        done
    } >"$1/usr/share/applications/mimeinfo.cache"
}

check() {
    run env ROOT="$1" "$SH" "$CHECKS/mime.sh"
}

check "$(mkroot good)"
expect_rc "F45's defaults pass" 0
expect_out "Loupe opens images" '^PASS mime: image/png opens org\.gnome\.Loupe\.desktop$'
expect_out "Decibels takes FLAC as the only app that claims it" '^PASS mime: audio/flac opens org\.gnome\.Decibels\.desktop$'
expect_out "Builder is not installed: Python opens in Text Editor through text/plain" \
    '^PASS mime: text/x-python opens org\.gnome\.TextEditor\.desktop$'
expect_out "Epiphany is the https handler" '^PASS mime: x-scheme-handler/https opens org\.gnome\.Epiphany\.desktop$'

r=$(mkroot moved)
sed -i 's/^image\/png=.*/image\/png=org.gnome.Other.desktop;org.gnome.Papers.desktop/' "$r/usr/share/applications/gnome-mimeapps.list"
sed -i 's/^MimeType=application\/pdf;/MimeType=application\/pdf;image\/png;/' "$r/usr/share/applications/org.gnome.Papers.desktop"
mimeinfo "$r"
check "$r"
expect_rc "a default that moved fails" 1
expect_out "naming the type, the app it opens and the one it should" \
    '^FAIL mime: image/png opens org\.gnome\.Papers\.desktop, not org\.gnome\.Loupe\.desktop'
expect_out "the rest still pass" '^PASS mime: image/jpeg opens org\.gnome\.Loupe\.desktop$'

r=$(mkroot noapp)
rm "$r/usr/share/applications/org.gnome.Showtime.desktop"
mimeinfo "$r"
check "$r"
expect_rc "an app that is not installed fails" 1
expect_out "and says nothing opens the type" '^FAIL mime: video/mp4 opens no app, not org\.gnome\.Showtime\.desktop'

r=$(mkroot nobinary)
rm "$r/usr/bin/nautilus"
check "$r"
expect_rc "a desktop file without its binary is no default" 1
expect_out "naming the type" '^FAIL mime: inode/directory opens no app'

r=$(mkroot builder)
printf '#!/bin/sh\n' >"$r/usr/bin/gnome-builder"
chmod +x "$r/usr/bin/gnome-builder"
printf '[Desktop Entry]\nType=Application\nName=Builder\nExec=gnome-builder\nMimeType=text/x-python;\n' \
    >"$r/usr/share/applications/org.gnome.Builder.desktop"
mimeinfo "$r"
check "$r"
expect_rc "an installed Builder takes Python files back" 1
expect_out "and is named" '^FAIL mime: text/x-python opens org\.gnome\.Builder\.desktop, not org\.gnome\.TextEditor\.desktop'

done_testing
