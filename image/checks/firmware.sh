#!/bin/sh
# Every glob of firmware-files.txt matches a file under /usr/lib/firmware; a dangling
# symlink does not count.
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
    case $glob in
        /* | *..*)
            fail "invalid glob (absolute or contains ..): $glob"
            continue
            ;;
    esac
    found=0
    # Unquoted: the shell expands the glob.
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
