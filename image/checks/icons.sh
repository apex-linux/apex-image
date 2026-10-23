#!/bin/sh
# Every installed .desktop file's Icon= resolves as GTK resolves it: a path that exists, or
# a name in the default icon theme, the themes it inherits, hicolor, or the unthemed dirs.
set -eu
CHECK_NAME=icons
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

SCHEMAS=/usr/share/glib-2.0/schemas
APPLICATIONS=/usr/share/applications
ICON_BASES='/usr/share/icons
/usr/share/pixmaps'

make_tmpdir

if ! command -v glib-compile-schemas >/dev/null 2>&1 || ! command -v gsettings >/dev/null 2>&1; then
    fail "glib-compile-schemas or gsettings not found"
    finish
fi

mkdir "$TMPD/schemas" "$TMPD/nodata"
for f in "$(rootpath "$SCHEMAS")"/*.gschema.xml "$(rootpath "$SCHEMAS")"/*.gschema.override; do
    if [ -f "$f" ]; then cp "$f" "$TMPD/schemas/"; fi
done
if ! glib-compile-schemas "$TMPD/schemas" >"$TMPD/out" 2>&1; then
    fail "the schemas under $SCHEMAS do not compile: $(head -n 3 "$TMPD/out" | paste -sd '|' -)"
    finish
fi
if ! theme=$(env -i PATH="$PATH" GSETTINGS_SCHEMA_DIR="$TMPD/schemas" GSETTINGS_BACKEND=memory \
    XDG_DATA_DIRS="$TMPD/nodata" gsettings get org.gnome.desktop.interface icon-theme 2>"$TMPD/out" </dev/null); then
    fail "no default for org.gnome.desktop.interface icon-theme under $SCHEMAS: $(head -n 1 "$TMPD/out")"
    finish
fi
theme=${theme#\'}
theme=${theme%\'}

# ini_get FILE GROUP KEY: the value, or nothing.
ini_get() {
    awk -v grp="[$2]" -v key="$3" '
        /^\[/ { in_grp = ($0 == grp); next }
        in_grp && index($0, key) == 1 {
            v = substr($0, length(key) + 1)
            if (v !~ /^[[:space:]]*=/) next
            sub(/^[[:space:]]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            print v; exit
        }' "$1"
}

list() {
    tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

theme_index() {
    printf '%s\n' "$ICON_BASES" | while IFS= read -r base; do
        if [ -f "$(rootpath "$base/$1/index.theme")" ]; then
            rootpath "$base/$1/index.theme"
            break
        fi
    done
}

# GTK's order: the theme, then depth first what it inherits, each once, and hicolor last.
printf '%s\nhicolor\n' "$theme" >"$TMPD/todo"
: >"$TMPD/seen"
: >"$TMPD/chain"
while [ -s "$TMPD/todo" ]; do
    t=$(head -n 1 "$TMPD/todo")
    tail -n +2 "$TMPD/todo" >"$TMPD/todo.rest"
    mv "$TMPD/todo.rest" "$TMPD/todo"
    if grep -qxF -- "$t" "$TMPD/seen"; then continue; fi
    printf '%s\n' "$t" >>"$TMPD/seen"
    index=$(theme_index "$t")
    if [ -z "$index" ]; then
        if [ "$t" = "$theme" ]; then
            fail "the default icon theme '$t' (org.gnome.desktop.interface icon-theme) has no index.theme under $(printf '%s\n' "$ICON_BASES" | paste -sd ' ' -)"
        else
            warn "the icon theme '$t' has no index.theme: GTK skips it"
        fi
        continue
    fi
    printf '%s\n' "$t" >>"$TMPD/chain"
    { ini_get "$index" 'Icon Theme' Inherits | list; cat "$TMPD/todo"; } >"$TMPD/todo.new"
    mv "$TMPD/todo.new" "$TMPD/todo"
    {
        ini_get "$index" 'Icon Theme' Directories | list
        ini_get "$index" 'Icon Theme' ScaledDirectories | list
    } >"$TMPD/dirs"
    printf '%s\n' "$ICON_BASES" | while IFS= read -r base; do
        while IFS= read -r d; do
            dir=$(rootpath "$base/$t/$d")
            if [ -d "$dir" ]; then
                find -L "$dir" -maxdepth 1 -type f \( -name '*.png' -o -name '*.svg' -o -name '*.xpm' \)
            fi
        done <"$TMPD/dirs"
    done >>"$TMPD/files"
done
printf '%s\n' "$ICON_BASES" | while IFS= read -r base; do
    dir=$(rootpath "$base")
    if [ -d "$dir" ]; then
        find -L "$dir" -maxdepth 1 -type f \( -name '*.png' -o -name '*.svg' -o -name '*.xpm' \)
    fi
done >>"$TMPD/files"
sed -e 's|.*/||' -e 's/\.[^.]*$//' "$TMPD/files" | LC_ALL=C sort -u >"$TMPD/names"

# Hidden=true means deleted; NoDisplay entries still show their icon (switcher, Open With).
apps=$(rootpath "$APPLICATIONS")
find "$apps" -type f -name '*.desktop' -exec awk '
    function flush() { if (file != "" && !hidden) printf "%s\t%s\n", file, icon }
    FNR == 1 { flush(); file = FILENAME; grp = ""; icon = ""; hidden = 0 }
    /^\[/ { grp = $0; next }
    grp == "[Desktop Entry]" && /^Icon[[:space:]]*=/ {
        icon = $0; sub(/^[^=]*=[[:space:]]*/, "", icon); sub(/[[:space:]]+$/, "", icon)
    }
    grp == "[Desktop Entry]" && /^Hidden[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { hidden = 1 }
    END { flush() }' {} + 2>/dev/null | LC_ALL=C sort >"$TMPD/entries" || true

entries=$(wc -l <"$TMPD/entries" | tr -d ' ')
if [ "$entries" -eq 0 ]; then
    fail "no .desktop file under $APPLICATIONS, Hidden=true ones aside"
    finish
fi

tab=$(printf '\t')
bad=0
noicon=0
while IFS="$tab" read -r file icon; do
    case $icon in
        '')
            noicon=$((noicon + 1))
            continue
            ;;
        /*)
            [ -f "$(rootpath "$icon")" ] && continue
            fail "$(unroot "$file"): Icon=$icon does not exist"
            ;;
        *)
            name=$icon
            case $name in *.png | *.svg | *.xpm) name=${name%.*} ;; esac
            grep -qxF -- "$name" "$TMPD/names" && continue
            fail "$(unroot "$file"): Icon=$icon is in none of the icon themes $(paste -sd ',' "$TMPD/chain" | sed 's/,/, /g') nor in $(printf '%s\n' "$ICON_BASES" | paste -sd ' ' -)"
            ;;
    esac
    bad=1
done <"$TMPD/entries"

if [ "$bad" -eq 0 ]; then
    pass "the Icon= of the $((entries - noicon)) desktop file(s) under $APPLICATIONS resolve with the icon theme '$theme' ($(paste -sd ',' "$TMPD/chain" | sed 's/,/ → /g')); $noicon have none"
fi

finish
