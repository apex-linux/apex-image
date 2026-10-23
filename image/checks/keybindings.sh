#!/bin/sh
# No two default keybindings share a combination across GNOME's keybinding schemas and
# the Apex one, as the compiled schemas give them with the vendor override applied.
set -eu
CHECK_NAME=keybindings
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

SCHEMAS=/usr/share/glib-2.0/schemas
KEYBINDING_SCHEMAS='org.gnome.desktop.wm.keybindings
org.gnome.mutter.keybindings
org.gnome.mutter.wayland.keybindings
org.gnome.shell.keybindings
org.gnome.settings-daemon.plugins.media-keys
io.github.apex_linux.Apex.Desktop.Keybindings'

make_tmpdir

if ! command -v glib-compile-schemas >/dev/null 2>&1 || ! command -v gsettings >/dev/null 2>&1; then
    fail "glib-compile-schemas or gsettings not found"
    finish
fi

mkdir "$TMPD/schemas" "$TMPD/nodata"
copy_schemas "$TMPD/schemas" overrides
if ! glib-compile-schemas "$TMPD/schemas" >"$TMPD/out" 2>&1; then
    fail "the schemas under $SCHEMAS do not compile: $(head -n 3 "$TMPD/out" | paste -sd '|' -)"
    finish
fi

# XDG_DATA_DIRS keeps the host's schemas out: only the root's count.
: >"$TMPD/settings"
missing=0
printf '%s\n' "$KEYBINDING_SCHEMAS" >"$TMPD/ids"
while IFS= read -r id; do
    if env -i PATH="$PATH" GSETTINGS_SCHEMA_DIR="$TMPD/schemas" GSETTINGS_BACKEND=memory \
        XDG_DATA_DIRS="$TMPD/nodata" gsettings list-recursively "$id" >>"$TMPD/settings" 2>"$TMPD/out" </dev/null; then
        :
    else
        fail "no schema $id under $SCHEMAS: its bindings were not checked"
        missing=1
    fi
done <"$TMPD/ids"

# One line per binding: the combination with modifiers aliased and sorted, then schema
# and key. An accelerator is <Mod>...keysym; paths (custom-keybindings) are not bindings.
awk '
function norm(a,    mods, n, i, j, t, m, out) {
    n = 0
    while (match(a, /^<[^>]*>/)) {
        m = tolower(substr(a, 2, RLENGTH - 2))
        a = substr(a, RLENGTH + 1)
        if (m == "ctrl" || m == "primary") m = "control"
        else if (m == "mod1") m = "alt"
        else if (m == "mod4") m = "super"
        mods[++n] = m
    }
    for (i = 2; i <= n; i++)
        for (j = i; j > 1 && mods[j - 1] > mods[j]; j--) { t = mods[j]; mods[j] = mods[j - 1]; mods[j - 1] = t }
    out = ""
    for (i = 1; i <= n; i++) if (i == 1 || mods[i] != mods[i - 1]) out = out "<" mods[i] ">"
    return out tolower(a)
}
{
    schema = $1; key = $2
    sub(/^[^ ]+ [^ ]+ /, "")
    v = $0
    while (match(v, /\047[^\047]*\047/)) {
        a = substr(v, RSTART + 1, RLENGTH - 2)
        v = substr(v, RSTART + RLENGTH)
        if (a == "" || a == "disabled" || a ~ /^\//) continue
        print norm(a), schema, key, a
    }
}' "$TMPD/settings" | LC_ALL=C sort -u -k1,3 >"$TMPD/bindings"

awk '{ n[$1]++; who[$1] = who[$1] (n[$1] > 1 ? " and " : "") $2 " " $3 " (" $4 ")" }
    END { for (c in n) if (n[c] > 1) print c ": " who[c] }' "$TMPD/bindings" | LC_ALL=C sort >"$TMPD/shared"

if [ -s "$TMPD/shared" ]; then
    while IFS= read -r line; do
        fail "two default bindings share ${line%%:*}:${line#*:}"
    done <"$TMPD/shared"
elif [ "$missing" -eq 0 ]; then
    pass "$(wc -l <"$TMPD/bindings" | tr -d ' ') default bindings across $(wc -l <"$TMPD/ids" | tr -d ' ') schemas share no combination"
fi

finish
