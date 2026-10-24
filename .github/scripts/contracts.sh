#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

The contracts between the image and the components it takes, checked against the
component checkouts APEX_SYSTEM_SRC, APEX_DESKTOP_SRC and APEX_GNOME_SRC (default: the
pinned clones of tools/components.sh fetch).

  contracts.sh      exit 0 when every contract holds
EOF
    exit 2
}

(($# == 0)) || usage
require python3 cmp

python3 - "$APEX_SYSTEM_SRC/hardware/m7400qc/profile.toml" "$APEX_ROOT/image" <<'EOF' || die "contracts: see above"
import pathlib
import sys
import tomllib

profile_path, image = sys.argv[1], pathlib.Path(sys.argv[2])
with open(profile_path, "rb") as f:
    firmware = tomllib.load(f)["firmware"]


def listed(path):
    names = (line.split("#")[0].strip() for line in path.read_text().splitlines())
    return [name for name in names if name]


problems = []
base = listed(image / "packages/base.txt")
missing = [p for p in firmware["packages"] if p not in base]
if missing:
    problems.append(f"image/packages/base.txt lacks [firmware].packages of {profile_path}: {' '.join(missing)}")
files = listed(image / "checks/firmware-files.txt")
if files != firmware["required_files"]:
    problems.append(
        f"image/checks/firmware-files.txt is not [firmware].required_files of {profile_path}, in order:\n"
        f"  list:    {' '.join(files)}\n  profile: {' '.join(firmware['required_files'])}"
    )
for p in problems:
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
log "contracts: the image installs and checks the firmware of the hardware profile"

python3 - "$APEX_ROOT/image/Containerfile" "$APEX_SYSTEM_SRC/crates/apexctl/src/manifest.rs" <<'EOF' || die "contracts: see above"
import re
import sys

containerfile, manifest_rs = (open(p, encoding="utf-8").read() for p in sys.argv[1:])
written = set(re.findall(r'echo ([a-z0-9-]+) >>"\$degraded"', containerfile))
accepted = re.search(r"DEGRADED_COMPONENTS: &\[&str\] = &\[([^\]]*)\]", manifest_rs)
if not written or not accepted:
    sys.exit("error: found no degraded names in the Containerfile, or no DEGRADED_COMPONENTS in apexctl")
refused = sorted(written - set(re.findall(r'"([^"]+)"', accepted.group(1))))
if refused:
    sys.exit(f"error: the Containerfile can label the image degraded={','.join(refused)}, "
             f"but the pinned apexctl build manifest refuses it ({sys.argv[2]})")
EOF
log "contracts: apexctl build manifest accepts every degraded name the image can write"

# Every layer feature must be a choice of the kill switch: gsettings refuses any other name.
gnome=$(component_at apex-gnome "$APEX_GNOME_SRC")
desktop=$(component_at apex-desktop "$APEX_DESKTOP_SRC")
features=$(layer_features "$APEX_GNOME_SRC/$APEX_LAYER_JS" 2>/dev/null) ||
    die "contracts: $gnome's $APEX_LAYER_JS has no FEATURES_IN_ENABLE_ORDER, or it is empty"
choices=$(python3 - "$APEX_DESKTOP_SRC/desktop/schemas/io.github.apex_linux.Apex.Desktop.gschema.xml" <<'EOF'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except (OSError, ET.ParseError) as e:
    sys.exit(f"error: cannot read {sys.argv[1]}: {e}")
key = root.find("./schema[@id='io.github.apex_linux.Apex.Desktop']/key[@name='disabled-features']")
if key is None:
    sys.exit("error: schema io.github.apex_linux.Apex.Desktop has no disabled-features key")
names = [c.get("value") for c in key.findall("./choices/choice")]
if not names:
    sys.exit("error: disabled-features has no <choices>: it takes any name, so none can be checked")
print("\n".join(names))
EOF
) || die "contracts: $desktop: see above"
lacking=$(comm -23 <(sort -u <<<"$features") <(sort -u <<<"$choices") | paste -sd' ' -)
[[ -z $lacking ]] ||
    die "contracts: $gnome's layer has features that $desktop's disabled-features cannot turn off (not in its <choices>): $lacking"
unused=$(comm -13 <(sort -u <<<"$features") <(sort -u <<<"$choices") | paste -sd' ' -)
[[ -z $unused ]] || warn "contracts: $desktop's disabled-features offers choices that $gnome's layer has no feature for: $unused"
log "contracts: every feature of $gnome's layer can be turned off by $desktop's disabled-features"

# Copies of one component's files that another keeps, by explicit path, so a moved copy
# fails too: COPY ORIGINAL pairs.
readonly SCHEMA=io.github.apex_linux.Apex.Desktop.gschema.xml
copies=(
    "$APEX_GNOME_SRC/tests/layer/fixtures/$SCHEMA" "$APEX_DESKTOP_SRC/desktop/schemas/$SCHEMA"
    "$APEX_GNOME_SRC/tests/layer/fixtures/apex-shell-safe.service"
    "$APEX_DESKTOP_SRC/desktop/systemd/user/apex-shell-safe.service"
)
if [[ -d $APEX_SYSTEM_SRC/crates/apex-session-agent ]]; then
    copies+=("$APEX_SYSTEM_SRC/crates/apex-session-agent/tests/data/$SCHEMA" "$APEX_DESKTOP_SRC/desktop/schemas/$SCHEMA")
fi
# Settings' Software Updates page generates its D-Bus code from a copy of Update1's XML.
readonly UPDATE1=io.github.apex_linux.Apex.Update1.xml
if [[ -e $APEX_GNOME_SRC/desktop/control-center/panels/apex/$UPDATE1 ]]; then
    copies+=("$APEX_GNOME_SRC/desktop/control-center/panels/apex/$UPDATE1" "$APEX_SYSTEM_SRC/crates/apex-dbus/data/$UPDATE1")
fi
stale=0
for ((i = 0; i < ${#copies[@]}; i += 2)); do
    if [[ ! -f ${copies[i + 1]} ]]; then
        printf 'error: %s is missing\n' "${copies[i + 1]}" >&2
        stale=1
    elif ! cmp -s -- "${copies[i]}" "${copies[i + 1]}"; then
        printf 'error: %s is missing or differs from %s: copy it from the pinned original\n' \
            "${copies[i]}" "${copies[i + 1]}" >&2
        stale=1
    fi
done
((stale == 0)) || die "contracts: see above"
log "contracts: every copy of a component's file equals the pinned original"
