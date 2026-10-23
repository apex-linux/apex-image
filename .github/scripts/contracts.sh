#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

The contracts between the image and the components it takes, checked against the
component checkouts APEX_SYSTEM_SRC and APEX_DESKTOP_SRC (default: this checkout).

  contracts.sh      exit 0 when every contract holds
EOF
    exit 2
}

(($# == 0)) || usage
require python3

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
