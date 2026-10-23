#!/bin/sh
# image/checks/icons.sh on fake roots with apex-desktop's override, and in fedora:45 on
# Fedora's icon themes and a few of the image's apps.
. "$(dirname -- "$0")/lib.sh"

command -v glib-compile-schemas >/dev/null 2>&1 || skip_all "glib-compile-schemas not found"
command -v gsettings >/dev/null 2>&1 || skip_all "gsettings not found"

DESKTOP=$APEX_DESKTOP_SRC/desktop
SCHEMAS=usr/share/glib-2.0/schemas
APPS=usr/share/applications
ICONS=usr/share/icons

# theme NAME INHERITS DIR...: an index.theme listing DIRs; INHERITS may be empty.
theme() {
    name=$1
    inherits=$2
    shift 2
    mkdir -p "$r/$ICONS/$name"
    {
        printf '[Icon Theme]\nName=%s\n' "$name"
        if [ -n "$inherits" ]; then printf 'Inherits=%s\n' "$inherits"; fi
        printf 'Directories=%s\n' "$(printf '%s\n' "$@" | paste -sd ',' -)"
        for d in "$@"; do printf '\n[%s]\nSize=48\n' "$d"; done
    } >"$r/$ICONS/$name/index.theme"
}

icon() {
    mkdir -p "$r/${1%/*}"
    printf 'icon\n' >"$r/$1"
}

# app ID LINES...: a desktop file with these lines after Type=Application.
app() {
    id=$1
    shift
    mkdir -p "$r/$APPS"
    { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$id" "$id"; printf '%s\n' "$@"; } \
        >"$r/$APPS/$id.desktop"
}

# default_theme NAME: an override after apex-desktop's, so its icon-theme does not matter.
default_theme() {
    printf "[org.gnome.desktop.interface]\nicon-theme='%s'\n" "$1" >"$r/$SCHEMAS/95_test-icons.gschema.override"
}

# mkroot NAME: GNOME's icon-theme key, apex-desktop's schemas and override, Adwaita as the
# default, and an app for each way an Icon= resolves.
mkroot() {
    r=$T/$1
    mkdir -p "$r/$SCHEMAS"
    cp "$DESKTOP"/schemas/*.gschema.xml "$DESKTOP"/schemas/*.gschema.override "$r/$SCHEMAS/"
    printf '%s\n' '<schemalist><schema id="org.gnome.desktop.interface" path="/org/gnome/desktop/interface/">' \
        '<key name="icon-theme" type="s"><default>'"'Adwaita'"'</default></key>' \
        '<key name="font-name" type="s"><default>'"'Cantarell 11'"'</default></key>' \
        '</schema></schemalist>' >"$r/$SCHEMAS/org.gnome.desktop.interface.gschema.xml"
    default_theme Adwaita
    theme Adwaita hicolor scalable/apps symbolic/apps
    theme hicolor '' 48x48/apps scalable/apps
    icon "$ICONS/Adwaita/scalable/apps/org.gnome.Themed.svg"
    icon "$ICONS/hicolor/48x48/apps/org.gnome.Inherited.png"
    icon "$ICONS/hicolor/scalable/apps/org.gnome.Suffixed.svg"
    icon usr/share/pixmaps/legacy-app.xpm
    icon usr/share/absolute/app.png
    app org.gnome.Themed Icon=org.gnome.Themed
    app org.gnome.Inherited Icon=org.gnome.Inherited
    app org.gnome.Suffixed Icon=org.gnome.Suffixed.svg
    app legacy-app Icon=legacy-app
    app absolute 'Icon=/usr/share/absolute/app.png'
    app hidden-from-menus NoDisplay=true Icon=org.gnome.Themed
    app no-icon Terminal=false
    app deleted Hidden=true Icon=nowhere
    app with-action Icon=org.gnome.Themed Actions=new '' '[Desktop Action new]' Name=New Icon=nowhere
}

icons() {
    run env ROOT="$T/$1" "$SH" "$CHECKS/icons.sh"
}

mkroot good
icons good
expect_rc "a themed, an inherited, a suffixed, a pixmap and an absolute Icon= pass" 0
expect_out "and names the theme and its chain" "^PASS icons: the Icon= of the 7 desktop file\(s\) under /usr/share/applications resolve with the icon theme 'Adwaita' \(Adwaita → hicolor\); 1 have none$"

mkroot missing
app org.gnome.Missing Icon=org.gnome.Missing
icons missing
expect_rc "an Icon= in no theme fails" 1
expect_out "naming the desktop file, the icon and the themes" '^FAIL icons: /usr/share/applications/org\.gnome\.Missing\.desktop: Icon=org\.gnome\.Missing is in none of the icon themes Adwaita, hicolor nor in /usr/share/icons /usr/share/pixmaps$'
expect_no_out "with no pass line" '^PASS icons: the Icon='

mkroot gone
app gone 'Icon=/usr/share/absolute/gone.png'
icons gone
expect_rc "an absolute Icon= that does not exist fails" 1
expect_out "and is named" '^FAIL icons: /usr/share/applications/gone\.desktop: Icon=/usr/share/absolute/gone\.png does not exist$'

mkroot unlisted
icon "$ICONS/hicolor/256x256/apps/org.gnome.Unlisted.png"
app org.gnome.Unlisted Icon=org.gnome.Unlisted
icons unlisted
expect_rc "an icon in a directory index.theme does not list fails, as GTK never reads it" 1
expect_out "and is named" '^FAIL icons: /usr/share/applications/org\.gnome\.Unlisted\.desktop: Icon=org\.gnome\.Unlisted is in none of'

mkroot apex
default_theme Apex
theme Apex Adwaita,hicolor scalable/apps
icon "$ICONS/Apex/scalable/apps/org.gnome.Colloid.svg"
app org.gnome.Colloid Icon=org.gnome.Colloid
icons apex
expect_rc "an Apex theme over Adwaita and hicolor, set by an override, passes" 0
expect_out "and names its chain" "^PASS icons: the Icon= of the 8 desktop file\(s\) under /usr/share/applications resolve with the icon theme 'Apex' \(Apex → Adwaita → hicolor\); 1 have none$"

# Colloid's aliases are relative links inside the theme.
mkroot links
default_theme Apex
theme Apex Adwaita,hicolor scalable/apps
icon "$ICONS/Apex/scalable/apps/org.gnome.Colloid.svg"
ln -s org.gnome.Colloid.svg "$r/$ICONS/Apex/scalable/apps/org.gnome.Alias.svg"
app org.gnome.Alias Icon=org.gnome.Alias
icons links
expect_rc "a link to an icon in the theme resolves" 0
ln -s org.gnome.Absent.svg "$r/$ICONS/Apex/scalable/apps/org.gnome.Dangling.svg"
ln -s org.gnome.Loop.svg "$r/$ICONS/Apex/scalable/apps/org.gnome.Loop.svg"
app org.gnome.Dangling Icon=org.gnome.Dangling
app org.gnome.Loop Icon=org.gnome.Loop
icons links
expect_rc "a dangling link and a link loop do not resolve" 1
expect_out "the dangling link is named" '^FAIL icons: /usr/share/applications/org\.gnome\.Dangling\.desktop: Icon=org\.gnome\.Dangling is in none of the icon themes Apex, Adwaita, hicolor nor'
expect_out "the link loop is named" '^FAIL icons: /usr/share/applications/org\.gnome\.Loop\.desktop: Icon=org\.gnome\.Loop is in none of'

# apex-desktop's own override, with its Apex index.theme once it ships one.
mkroot desktop
rm "$r/$SCHEMAS/95_test-icons.gschema.override"
if [ -f "$DESKTOP/icons/index.theme" ]; then
    mkdir -p "$r/$ICONS/Apex"
    cp "$DESKTOP/icons/index.theme" "$r/$ICONS/Apex/"
fi
icons desktop
sed -En 's/^PASS icons: the Icon=/# apex-desktop: &/p' "$T/out"
expect_rc "apex-desktop's override and index.theme pass" 0

mkroot cycle
default_theme Apex
theme Apex Loop scalable/apps
theme Loop Apex,Adwaita scalable/apps
icon "$ICONS/Loop/scalable/apps/org.gnome.Looped.svg"
app org.gnome.Looped Icon=org.gnome.Looped
icons cycle
expect_rc "a theme cycle in Inherits ends, and the icons in it resolve" 0
expect_out "with each theme once" "resolve with the icon theme 'Apex' \(Apex → Loop → Adwaita → hicolor\); 1 have none$"

mkroot noindex
default_theme Apex
icon "$ICONS/Apex/scalable/apps/org.gnome.Colloid.svg"
icons noindex
expect_rc "a default theme without index.theme fails" 1
expect_out "and is named" "^FAIL icons: the default icon theme 'Apex' \(org\.gnome\.desktop\.interface icon-theme\) has no index\.theme under /usr/share/icons /usr/share/pixmaps$"

mkroot noinherited
theme Adwaita Gone,hicolor scalable/apps
icon "$ICONS/Gone/scalable/apps/org.gnome.Orphan.svg"
app org.gnome.Orphan Icon=org.gnome.Orphan
icons noinherited
expect_rc "an icon only in an inherited theme without index.theme fails" 1
expect_out "the theme is skipped with a warning" "^WARN icons: the icon theme 'Gone' has no index\.theme: GTK skips it$"
expect_out "and the icon is named" '^FAIL icons: /usr/share/applications/org\.gnome\.Orphan\.desktop: Icon=org\.gnome\.Orphan is in none of the icon themes Adwaita, hicolor nor'

mkroot noapps
rm -r "${r:?}/$APPS"
icons noapps
expect_rc "no desktop file fails" 1
expect_out "and says so" '^FAIL icons: no \.desktop file under /usr/share/applications, Hidden=true ones aside$'

mkroot noschema
rm "$r/$SCHEMAS/org.gnome.desktop.interface.gschema.xml"
icons noschema
expect_rc "no icon-theme key fails" 1
expect_out "and names the key" '^FAIL icons: no default for org\.gnome\.desktop\.interface icon-theme under '

# glib-compile-schemas skips a file it cannot parse and exits 0.
mkroot broken
printf '<schemalist><schema id="org.gnome.desktop.interface">\n' >"$r/$SCHEMAS/org.gnome.desktop.interface.gschema.xml"
icons broken
expect_rc "an interface schema that does not parse fails" 1
expect_out "with glib-compile-schemas' warning" '^FAIL icons: no default for org\.gnome\.desktop\.interface icon-theme under .*; glib-compile-schemas: .*org\.gnome\.desktop\.interface\.gschema\.xml'

# Fedora's themes and the desktop files of a few of the image's apps, unpacked.
if grep -qx 'ID=fedora' /etc/os-release 2>/dev/null && command -v dnf5 >/dev/null 2>&1; then
    r=$T/fedora
    mkdir -p "$r/rpms"
    run dnf5 -q download --repo=fedora --repo=updates --arch=x86_64 --arch=noarch --destdir="$r/rpms" \
        gsettings-desktop-schemas adwaita-icon-theme hicolor-icon-theme nautilus gnome-text-editor ptyxis
    expect_rc "dnf5 downloads Fedora's icon themes and apps" 0
    for p in "$r"/rpms/*.rpm; do
        (cd "$r" && rpm2cpio "$p" | cpio -idm --quiet './usr/share/*')
    done
    cp "$DESKTOP"/schemas/*.gschema.xml "$DESKTOP"/schemas/*.gschema.override "$r/$SCHEMAS/"
    if [ -f "$DESKTOP/icons/index.theme" ]; then
        mkdir -p "$r/$ICONS/Apex"
        cp "$DESKTOP/icons/index.theme" "$r/$ICONS/Apex/"
    fi
    run env ROOT="$r" "$SH" "$CHECKS/icons.sh"
    expect_true "the downloads hold Fedora's Adwaita theme" test -f "$r/$ICONS/Adwaita/index.theme"
    sed -En 's/^(PASS|WARN|FAIL) icons: /# fedora: &/p' "$T/out"
    printf '# fedora: %s\n' "$(find "$r/$SCHEMAS" -maxdepth 1 -type f -name '*.gschema.*' | sed 's|.*/||' | sort | paste -sd ' ' -)"
    expect_rc "the apps' icons resolve in Fedora's themes with apex-desktop's override and theme" 0
fi

done_testing
