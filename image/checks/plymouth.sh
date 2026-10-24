#!/bin/sh
# The boot splash: the apex script theme at DeviceScale=1, its two-step fallback, and the
# same configuration and theme inside the initramfs that draws them.
set -eu
CHECK_NAME=plymouth
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

CONF=/etc/plymouth/plymouthd.conf
THEMES=/usr/share/plymouth/themes
MODDIR=$(rootpath /usr/lib/modules)
# DeviceScale=1 halves Plymouth's text, so the console viewer needs twice the 10 pt default.
MIN_MONOSPACE_PT=20

make_tmpdir

# daemon_key FILE KEY: the value of KEY in FILE's [Daemon] section, the last one winning.
daemon_key() {
    awk -v key="$2" '
        /^[[:space:]]*\[/ { daemon = ($0 ~ /^[[:space:]]*\[Daemon\][[:space:]]*$/); next }
        daemon {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (index(line, key "=") == 1) value = substr(line, length(key) + 2)
        }
        END { print value }' "$1"
}

# theme_key FILE SECTION KEY
theme_key() {
    awk -v section="[$2]" -v key="$3" '
        /^[[:space:]]*\[/ { inside = ($0 == section); next }
        inside && index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
        END { print value }' "$1"
}

check_conf() {
    where=$1
    file=$2
    theme=$(daemon_key "$file" Theme)
    scale=$(daemon_key "$file" DeviceScale)
    if [ "$theme" = apex ]; then
        pass "$where: [Daemon] Theme=apex"
    else
        fail "$where: [Daemon] Theme is '${theme:-unset}', not apex (plymouth-set-default-theme apex)"
    fi
    if [ "$scale" = 1 ]; then
        pass "$where: [Daemon] DeviceScale=1, so the script theme draws its @2x images 1:1"
    else
        fail "$where: [Daemon] DeviceScale is '${scale:-unset}', not 1: the script theme would draw upscaled, soft images"
    fi
}

if [ -f "$(rootpath "$CONF")" ]; then
    check_conf "$CONF" "$(rootpath "$CONF")"
else
    fail "no $CONF: Plymouth would draw Fedora's default theme"
fi

for t in apex:script apex-twostep:two-step; do
    name=${t%%:*}
    module=${t#*:}
    keyfile=$(rootpath "$THEMES/$name/$name.plymouth")
    if [ ! -f "$keyfile" ]; then
        fail "no $THEMES/$name/$name.plymouth (apex-desktop)"
        continue
    fi
    got=$(theme_key "$keyfile" 'Plymouth Theme' ModuleName)
    if [ "$got" = "$module" ]; then
        pass "$THEMES/$name uses the $module plugin"
    else
        fail "$THEMES/$name/$name.plymouth: ModuleName is '${got:-unset}', not $module"
    fi
    font=$(theme_key "$keyfile" "$module" MonospaceFont)
    pt=${font##* }
    case $pt in
        '' | *[!0-9]*) pt=0 ;;
    esac
    if [ "$pt" -ge "$MIN_MONOSPACE_PT" ]; then
        pass "$name: MonospaceFont=$font keeps the Esc text view legible at DeviceScale=1"
    else
        fail "$name: MonospaceFont is '${font:-unset}', under $MIN_MONOSPACE_PT pt: the Esc text view would be half size at DeviceScale=1"
    fi
done

set -- "$MODDIR"/*/initramfs.img
if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
    fail "expected one initramfs under /usr/lib/modules, found: $*"
    finish
fi
img=$1
if ! command -v lsinitrd >/dev/null 2>&1; then
    fail "lsinitrd not found on PATH; cannot read the initramfs's Plymouth files"
    finish
fi
if lsinitrd "$img" -f "${CONF#/}" >"$TMPD/conf" 2>/dev/null && [ -s "$TMPD/conf" ]; then
    check_conf "the initramfs's $CONF" "$TMPD/conf"
else
    fail "the initramfs has no $CONF: it boots Plymouth's built-in defaults"
fi
for f in "$THEMES/apex/apex.plymouth" "$THEMES/apex/apex.script"; do
    if lsinitrd "$img" -f "${f#/}" >"$TMPD/file" 2>/dev/null && [ -s "$TMPD/file" ]; then
        pass "the initramfs carries $f"
    else
        fail "the initramfs lacks $f: dracut ran before the theme was the default"
    fi
done
if lsinitrd "$img" >"$TMPD/listing" 2>"$TMPD/lsinitrd.err"; then
    if grep -Eq 'usr/lib64/plymouth/label-freetype\.so$' "$TMPD/listing" &&
        grep -Eq 'usr/share/fonts/.+\.(ttf|otf)$' "$TMPD/listing"; then
        pass "the initramfs carries label-freetype and a font: the Esc text view can draw the passphrase prompt"
    else
        fail "the initramfs lacks label-freetype.so or a font under /usr/share/fonts: the Esc text view would have no text"
    fi
else
    fail "lsinitrd failed on $img: $(head -n 3 "$TMPD/lsinitrd.err" | paste -sd ' ' -)"
fi

finish
