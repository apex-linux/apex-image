#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

vm-paths-check.sh ROOT

Checks that .github/scripts/vm-paths.txt in the checkout ROOT covers what a VM run reads,
and that vm.yml has no push trigger: gates.yml gives the verdict before a merge. It starts at
each listed file and each repository path vm.yml's run: steps name, and follows what every
reached script sources, runs or reads as data. A read that no path covers fails, as does a
dynamic path whose static part no path covers, unless .github/scripts/vm-paths-allowed.txt
gives that reader and path with a reason. tools/runner/README.md's "What a run does" must
name each path, and no file vm-paths.txt does not list.

  vm-paths-check.sh ROOT    exit 0 when the paths cover every read
EOF
    exit 2
}

(($# == 1)) || usage
exec python3 - "$1" "$(dirname "${BASH_SOURCE[0]}")" <<'EOF'
import os
import re
import subprocess
import sys

root, here = sys.argv[1:]
sys.dont_write_bytecode = True
sys.path.insert(0, here)
from repo_reads import Repo, allow_lines, references, walk  # noqa: E402

workflow, allowed_file, readme = ".github/workflows/vm.yml", ".github/scripts/vm-paths-allowed.txt", "tools/runner/README.md"
list_file = ".github/scripts/vm-paths.txt"
repo = Repo(root)
problems = []
read = repo.read
lines = read(workflow)
paths = [line.strip() for line in read(list_file) if line.strip() and not line.strip().startswith("#")]
steps, inside, on = [], None, False
for number, line in enumerate(lines, 1):
    if re.match(r"^on:\s*$", line):
        on = True
        continue
    if on and re.match(r"^\S", line):
        on = False
    if on and re.match(r"^  push:", line):
        problems.append(f"{workflow}:{number}: a push trigger; gates.yml gives the verdict before a merge, and vm.yml signs")
    m = re.match(r"^(\s*)(?:- )?run: *\|?\s*(.*)$", line)
    if m:
        inside, indent = "run", len(m[1])
        if m[2]:
            steps.append((number, m[2]))
        continue
    if inside == "run":
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            inside = None
        else:
            steps.append((number, line))
if not paths:
    sys.exit(f"error: {list_file} lists no path")


def covered(p):
    return any(p == q or (q.endswith("/**") and (p + "/").startswith(q[:-2])) for q in paths)


allowed = allow_lines(repo, allowed_file, problems)
queue = [(p, list_file) for p in paths if p in repo.tracked]
for number, token in references(workflow, steps):
    queue.append((token, f"{workflow}:{number}"))
seen, used = walk(repo, queue, covered, allowed, f"no {list_file} path covers", f"a {list_file} path", problems)
problems += [f"{allowed_file}:{n}: {r} {t} is no longer an uncovered read: delete the line" for (r, t), n in allowed.items() if (r, t) not in used]
text = "\n".join(read(readme))
section = re.search(r"What a run reads:(.*?)A change to them", text, re.S)
if not section:
    problems.append(f"{readme}: no \"What a run reads:\" list of the paths in {list_file}")
else:
    named = set(re.findall(r"`([^`\s]+)`|\b([\w-]+\.sh)\b", section[1]))
    named = {a or b for a, b in named if not (a or b).endswith("/") and ("." in (a or b) or "/" in (a or b))}
    problems += [f"{readme}: \"What a run does\" does not name {p}" for p in paths if p not in named and os.path.basename(p) not in named]
    problems += [
        f"{readme}: \"What a run does\" names {n}, which no {list_file} path is"
        for n in sorted(named)
        if n not in paths and n not in {os.path.basename(p) for p in paths}
    ]
for path in sorted(seen):
    print(f"reached {path} (from {seen[path]})")
for p in sorted(set(problems)):
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
