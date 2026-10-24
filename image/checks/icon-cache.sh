#!/bin/sh
# Without a cache GTK scans the Apex themes at every lookup; a stale one hides new glyphs.
set -eu
CHECK_NAME=icon-cache
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

ICONS=/usr/share/icons

if ! command -v gtk-update-icon-cache >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    fail "gtk-update-icon-cache or python3 not available: the Apex icon caches cannot be checked"
    finish
fi

themes=0
for dir in "$(rootpath "$ICONS")"/Apex "$(rootpath "$ICONS")"/Apex-*; do
    [ -f "$dir/index.theme" ] || continue
    themes=$((themes + 1))
    name=$ICONS/${dir##*/}
    if [ ! -f "$dir/icon-theme.cache" ]; then
        fail "$name has no icon-theme.cache: GTK scans its directories at every lookup (apex-desktop's %install builds it)"
        continue
    fi
    if ! gtk-update-icon-cache --validate "$dir" >/dev/null 2>&1; then
        fail "$name/icon-theme.cache is not a valid icon cache (gtk-update-icon-cache --validate)"
        continue
    fi
    rc=0
    out=$(python3 - "$dir" 2>&1 <<'PY'
import os
import struct
import sys

theme = sys.argv[1]
FLAGS = {".xpm": 1, ".svg": 2, ".png": 4}
data = open(os.path.join(theme, "icon-theme.cache"), "rb").read()


def u16(o):
    return struct.unpack_from(">H", data, o)[0]


def u32(o):
    return struct.unpack_from(">I", data, o)[0]


def string(o):
    return data[o:data.index(b"\0", o)].decode()


# GTK's icon cache: a header, a hash of icon names, and for each name its directories.
hash_offset, dir_offset = u32(4), u32(8)
dirs = [string(u32(dir_offset + 4 + 4 * i)) for i in range(u32(dir_offset))]
cached = set()
for bucket in range(u32(hash_offset)):
    icon = u32(hash_offset + 4 + 4 * bucket)
    while icon != 0xFFFFFFFF:
        name, images = string(u32(icon + 4)), u32(icon + 8)
        for i in range(u32(images)):
            flags = u16(images + 6 + 8 * i)
            for ext, bit in FLAGS.items():
                if flags & bit:
                    cached.add(("%s/%s%s" % (dirs[u16(images + 4 + 8 * i)], name, ext)))
        icon = u32(icon)

present = set()
for top, _, files in os.walk(theme, followlinks=True):
    rel = os.path.relpath(top, theme)
    if rel == ".":
        continue
    for f in files:
        if os.path.splitext(f)[1] in FLAGS and os.path.exists(os.path.join(top, f)):
            present.add("%s/%s" % (rel, f))

missing, gone = sorted(present - cached), sorted(cached - present)
if missing:
    print("lacks %d icon(s) present, first: %s" % (len(missing), " ".join(missing[:5])))
if gone:
    print("lists %d icon(s) not present, first: %s" % (len(gone), " ".join(gone[:5])))
if missing or gone:
    sys.exit(3)
print("%d icons in %d directories" % (len(cached), len(set(p.rsplit("/", 1)[0] for p in cached))))
PY
    ) || rc=$?
    case $rc in
        0) pass "$name/icon-theme.cache is valid and lists every icon present: $out" ;;
        3) fail "$name/icon-theme.cache is stale: it $(printf '%s' "$out" | paste -sd ';' - | sed 's/;/; it /g'); rebuild it with gtk-update-icon-cache" ;;
        *) fail "check error on $name/icon-theme.cache: $(printf '%s' "$out" | tail -n 1)" ;;
    esac
done

if [ "$themes" -eq 0 ]; then
    fail "no Apex icon theme (an index.theme in $ICONS/Apex or $ICONS/Apex-*)"
fi

finish
