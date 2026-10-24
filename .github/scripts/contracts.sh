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

# Copies of apex-desktop's files that components keep for their own tests, by explicit
# path, so a moved copy fails too: COPY ORIGINAL pairs.
readonly SCHEMA=io.github.apex_linux.Apex.Desktop.gschema.xml
copies=(
    "$APEX_GNOME_SRC/tests/layer/fixtures/$SCHEMA" "$APEX_DESKTOP_SRC/desktop/schemas/$SCHEMA"
    "$APEX_GNOME_SRC/tests/layer/fixtures/apex-shell-safe.service"
    "$APEX_DESKTOP_SRC/desktop/systemd/user/apex-shell-safe.service"
)
if [[ -d $APEX_SYSTEM_SRC/crates/apex-session-agent ]]; then
    copies+=("$APEX_SYSTEM_SRC/crates/apex-session-agent/tests/data/$SCHEMA" "$APEX_DESKTOP_SRC/desktop/schemas/$SCHEMA")
fi
stale=0
for ((i = 0; i < ${#copies[@]}; i += 2)); do
    if [[ ! -f ${copies[i + 1]} ]]; then
        printf 'error: %s is missing\n' "${copies[i + 1]}" >&2
        stale=1
    elif ! cmp -s -- "${copies[i]}" "${copies[i + 1]}"; then
        printf 'error: %s is missing or differs from %s: copy it from the pinned apex-desktop\n' \
            "${copies[i]}" "${copies[i + 1]}" >&2
        stale=1
    fi
done
((stale == 0)) || die "contracts: see above"
log "contracts: every copy of apex-desktop's files equals the pinned apex-desktop's"
