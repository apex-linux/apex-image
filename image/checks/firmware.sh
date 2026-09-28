#!/bin/sh
# Firmware presence (ARCHITECTURE 6.1).
#
# Weak dependencies are off, so the firmware packages are listed explicitly in
# image/packages/base.txt. This check proves the specific files the M7400QC loads are
# in the image: every glob in image/checks/firmware-files.txt (which mirrors
# hardware/m7400qc/profile.toml [firmware].required_files) must match at least one
# existing file under /usr/lib/firmware. Dangling symlinks do not count.
#
# Environment: ROOT (see lib/common.sh); FIRMWARE_FILES overrides the list path.
set -eu
CHECK_NAME=firmware
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

LIST=${FIRMWARE_FILES:-$APEX_CHECKS_DIR/firmware-files.txt}
FWDIR=$(rootpath /usr/lib/firmware)

if [ ! -r "$LIST" ]; then
    fail "list not readable: $LIST"
    finish
fi
if [ ! -d "$FWDIR" ]; then
    fail "no firmware directory: $FWDIR"
    finish
fi

make_tmpdir
read_list "$LIST" >"$TMPD/globs"
if [ ! -s "$TMPD/globs" ]; then
    fail "empty list: $LIST"
    finish
fi

while IFS= read -r glob; do
    # Reject anything that could escape the firmware directory.
    case $glob in
        /* | *..*)
            fail "invalid glob (absolute or contains ..): $glob"
            continue
            ;;
    esac
    found=0
    # Unquoted on purpose: let the shell expand the glob.
    for f in $FWDIR/$glob; do
        if [ -e "$f" ]; then
            found=$((found + 1))
        fi
    done
    if [ "$found" -gt 0 ]; then
        pass "$glob: $found file(s)"
    else
        fail "$glob: no file under $FWDIR"
    fi
done <"$TMPD/globs"

finish
