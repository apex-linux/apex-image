#!/bin/sh
# composefs holds the deployed root: ostree-prepare-root, in the initramfs, mounts / from
# a composefs image only when the prepare-root.conf it reads there enables it.
set -eu
CHECK_NAME=composefs
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

PREPARE_ROOT_CONF_SEARCH_PATH='etc/ostree/prepare-root.conf usr/lib/ostree/prepare-root.conf'
# "maybe" mounts composefs only when it can, so it does not count as on.
ON_VALUES='yes true 1 signed verity'

make_tmpdir

composefs_enabled() {
    awk '
        /^[[:space:]]*\[/ { section = $0; gsub(/[[:space:]]/, "", section); next }
        section == "[composefs]" && /^[[:space:]]*enabled[[:space:]]*=/ {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            enabled = value
        }
        END { print enabled }'
}

check_conf_enables_composefs() {
    where=$1
    conf=$2
    value=$(composefs_enabled <"$conf")
    for on in $ON_VALUES; do
        if [ "$value" = "$on" ]; then
            pass "$where: [composefs] enabled = $value"
            return 0
        fi
    done
    fail "$where: [composefs] enabled = ${value:-unset}, so / is not a composefs mount"
}

found=''
for p in $PREPARE_ROOT_CONF_SEARCH_PATH; do
    if [ -f "$(rootpath "/$p")" ]; then
        found=$p
        break
    fi
done
if [ -z "$found" ]; then
    fail "no /etc/ostree/prepare-root.conf or /usr/lib/ostree/prepare-root.conf"
else
    check_conf_enables_composefs "the image's /$found" "$(rootpath "/$found")"
fi

MODDIR=$(rootpath /usr/lib/modules)
set -- "$MODDIR"/*/initramfs.img
if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
    fail "expected one initramfs under /usr/lib/modules, found: $*"
    finish
fi
img=$1
if ! command -v lsinitrd >/dev/null 2>&1; then
    fail "lsinitrd not found on PATH; cannot read the initramfs's prepare-root.conf"
    finish
fi
found=''
for p in $PREPARE_ROOT_CONF_SEARCH_PATH; do
    if lsinitrd "$img" -f "$p" >"$TMPD/conf" 2>/dev/null && [ -s "$TMPD/conf" ]; then
        found=$p
        break
    fi
done
if [ -z "$found" ]; then
    fail "the initramfs has no prepare-root.conf, so ostree-prepare-root keeps its default"
else
    check_conf_enables_composefs "the initramfs's /$found" "$TMPD/conf"
fi

finish
