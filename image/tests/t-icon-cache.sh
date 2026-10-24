#!/bin/sh
# image/checks/icon-cache.sh: every Apex icon theme has a valid cache that lists each icon.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"
command -v gtk-update-icon-cache >/dev/null 2>&1 || skip_all "gtk-update-icon-cache not found"

ICONS=usr/share/icons
SVG='<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>'

# mkroot NAME: Apex and Apex-blue with a few icons, a link and a root-level file, cached.
mkroot() {
    r=$T/$1
    for theme in Apex Apex-blue; do
        t=$r/$ICONS/$theme
        mkdir -p "$t/symbolic" "$t/scalable/places" "$t/16x16/apps"
        printf '[Icon Theme]\nName=%s\nDirectories=symbolic,scalable/places,16x16/apps\n' "$theme" >"$t/index.theme"
        printf '%s\n' "$SVG" >"$t/symbolic/wifi-symbolic.svg"
        printf '%s\n' "$SVG" >"$t/scalable/places/folder.svg"
        ln -s folder.svg "$t/scalable/places/folder-documents.svg"
        printf 'png' >"$t/16x16/apps/app.png"
        printf '%s\n' "$SVG" >"$t/stray.svg"
        gtk-update-icon-cache --force --quiet "$t"
    done
    printf '%s\n' "$r"
}

check() {
    run env ROOT="$1" "$SH" "$CHECKS/icon-cache.sh"
}

check "$(mkroot good)"
expect_rc "cached themes pass" 0
expect_out "naming what each cache holds" \
    '^PASS icon-cache: /usr/share/icons/Apex/icon-theme.cache is valid and lists every icon present: 4 icons in 3 directories$'
expect_out "for the accent theme too" '^PASS icon-cache: /usr/share/icons/Apex-blue/icon-theme.cache is valid'

r=$(mkroot missing)
rm "$r/$ICONS/Apex-blue/icon-theme.cache"
check "$r"
expect_rc "a theme without a cache fails" 1
expect_out "and says GTK scans it" '^FAIL icon-cache: /usr/share/icons/Apex-blue has no icon-theme.cache: GTK scans'
expect_out "the other theme still passes" '^PASS icon-cache: /usr/share/icons/Apex/icon-theme.cache'

r=$(mkroot stale)
printf '%s\n' "$SVG" >"$r/$ICONS/Apex/symbolic/bluetooth-symbolic.svg"
check "$r"
expect_rc "an SVG the cache lacks fails" 1
expect_out "naming it" \
    '^FAIL icon-cache: /usr/share/icons/Apex/icon-theme.cache is stale: it lacks 1 icon\(s\) present, first: symbolic/bluetooth-symbolic.svg;'

r=$(mkroot removed)
rm "$r/$ICONS/Apex/scalable/places/folder-documents.svg"
check "$r"
expect_rc "a cached icon that is gone fails" 1
expect_out "naming it" 'it lists 1 icon\(s\) not present, first: scalable/places/folder-documents.svg'

r=$(mkroot invalid)
head -c 40 "$r/$ICONS/Apex/icon-theme.cache" >"$T/cut"
cp "$T/cut" "$r/$ICONS/Apex/icon-theme.cache"
check "$r"
expect_rc "a truncated cache fails" 1
expect_out "as invalid" '^FAIL icon-cache: /usr/share/icons/Apex/icon-theme.cache is not a valid icon cache'

r=$(mkroot rootlevel)
printf '%s\n' "$SVG" >"$r/$ICONS/Apex/another-stray.svg"
check "$r"
expect_rc "an SVG in the theme's root is not looked up, so not required" 0

r=$(mkroot other)
mkdir -p "$r/$ICONS/Colloid/scalable"
printf '[Icon Theme]\nName=Colloid\n' >"$r/$ICONS/Colloid/index.theme"
check "$r"
expect_rc "a non-Apex theme without a cache is not checked" 0

r=$T/none
mkdir -p "$r/$ICONS/hicolor"
check "$r"
expect_rc "no Apex theme fails" 1
expect_out "and says so" '^FAIL icon-cache: no Apex icon theme'

done_testing
