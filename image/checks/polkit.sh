#!/bin/sh
# polkitd skips what it cannot read and shows a missing vendor as blank in the shell's dialog.
set -eu
CHECK_NAME=polkit
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

ACTIONS_DIR=/usr/share/polkit-1/actions
VENDOR=Apex

set -- "$(rootpath "$ACTIONS_DIR")"/io.github.apex-linux.*.policy
if [ ! -e "$1" ]; then
    fail "no io.github.apex-linux.*.policy in $ACTIONS_DIR: apex-system's actions are missing"
    finish
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not available: the polkit actions cannot be checked"
    finish
fi

make_tmpdir
if ! python3 - "$ROOT" "$VENDOR" "$@" >"$TMPD/results" 2>"$TMPD/python.err" <<'PY'; then
import os
import sys
import xml.etree.ElementTree as ET

root, vendor = sys.argv[1:3]
LANG = "{http://www.w3.org/XML/1998/namespace}lang"


def shown(path):
    return "/" + os.path.relpath(path, root) if root != "/" else path


def text(elem, tag):
    """The untranslated element's text, as pkaction prints it; None when there is none."""
    for child in elem.findall(tag):
        if child.get(LANG) is None:
            return (child.text or "").strip()
    return None


for path in sys.argv[3:]:
    name = shown(path)
    try:
        doc = ET.parse(path).getroot()
    except ET.ParseError as e:
        print("bad %s does not parse (%s): polkitd may read only part of it" % (name, e))
        continue
    if doc.tag != "policyconfig":
        print("bad %s: the root element is <%s>, not <policyconfig>" % (name, doc.tag))
        continue
    actions = doc.findall("action")
    if not actions:
        print("bad %s has no <action>" % name)
        continue
    file_vendor = text(doc, "vendor")
    good = []
    for action in actions:
        aid = (action.get("id") or "").strip()
        if not aid:
            print("bad %s: an <action> has no id" % name)
            continue
        missing = [t for t in ("description", "message") if not text(action, t)]
        if action.find("defaults") is None:
            missing.append("defaults")
        if missing:
            print("bad %s: %s has no %s" % (name, aid, ", ".join(missing)))
            continue
        own = text(action, "vendor")
        have = own if own is not None else file_vendor
        if have != vendor:
            if own is not None:
                where = "its own <vendor>"
            elif file_vendor is not None:
                where = "the file's <vendor>"
            else:
                where = "no <vendor>"
            print("bad %s: %s's vendor is '%s' (%s), not '%s': the dialog's details show it"
                  % (name, aid, have or "", where, vendor))
            continue
        good.append(aid)
    if len(good) == len(actions):
        print("ok %s: %d actions, vendor %s: %s" % (name, len(good), vendor, " ".join(good)))
PY
    [ -s "$TMPD/python.err" ] || echo "python3 failed without a message" >"$TMPD/python.err"
    while IFS= read -r line; do fail "check error: $line"; done <"$TMPD/python.err"
fi

while IFS= read -r line; do
    case $line in
        'ok '*) pass "${line#ok }" ;;
        'bad '*) fail "${line#bad }" ;;
        *) fail "unexpected output: $line" ;;
    esac
done <"$TMPD/results"

finish
