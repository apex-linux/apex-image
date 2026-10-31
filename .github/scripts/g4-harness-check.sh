#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

g4-harness-check.sh ROOT

Checks that the harness line of G4's key covers what G4 runs on in the checkout ROOT. It starts at
qualify.sh, G4's entry point, and follows what every reached script sources, runs or reads as
data, as vm-paths-check.sh does. A repository file it reaches must be one that qualify.sh's
g4_harness hashes, or .github/scripts/g4-harness-allowed.txt must give that reader and path with
a reason: otherwise a change to it would not make G4 due.

  g4-harness-check.sh ROOT    exit 0 when the harness digest covers every read
EOF
    exit 2
}

(($# == 1)) || usage
exec python3 - "$1" "$(dirname "${BASH_SOURCE[0]}")" <<'EOF'
import re
import sys

root, here = sys.argv[1:]
sys.dont_write_bytecode = True
sys.path.insert(0, here)
from repo_reads import Repo, allow_lines, walk  # noqa: E402

entry, allowed_file = ".github/scripts/qualify.sh", ".github/scripts/g4-harness-allowed.txt"
repo = Repo(root)
problems = []
m = re.search(r'^g4_harness\(\) \{\n\s*\(cd "\$APEX_ROOT/([^"]+)" && sha256sum ([^)|]+)\)', "\n".join(repo.read(entry)), re.M)
if not m:
    sys.exit(f"error: {entry} has no g4_harness() that hashes files in one directory of the checkout")
digest = {f"{m[1]}/{name}" for name in m[2].split()}
problems += [f"{entry}: g4_harness hashes {f}, which is not in the checkout" for f in sorted(digest - repo.tracked)]
allowed = allow_lines(repo, allowed_file, problems)
seen, used = walk(repo, [(entry, "G4's entry point")], digest.__contains__, allowed, "g4_harness does not hash", "a file g4_harness hashes", problems)
problems += [f"{allowed_file}:{n}: {r} {t} is no longer an unhashed read: delete the line" for (r, t), n in allowed.items() if (r, t) not in used]
for path in sorted(seen):
    print(f"reached {path} (from {seen[path]}){'' if path in digest else ' — not hashed'}")
print(f"harness digest: {', '.join(sorted(digest))}")
for p in sorted(set(problems)):
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
