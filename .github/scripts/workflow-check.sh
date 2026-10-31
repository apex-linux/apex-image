#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

workflow-check.sh DIR ALLOWED

Checks every workflow in DIR: top-level permissions: {}, an explicit permissions: and
timeout-minutes: on each job, every uses: pinned to a 40-hex commit with a # version comment,
no pull_request_target, and no write permission unless ALLOWED has an exact
WORKFLOW JOB PERMISSION REASON line for it.

  workflow-check.sh DIR ALLOWED    exit 0 when every workflow passes
EOF
    exit 2
}

(($# == 2)) || usage
exec python3 - "$@" <<'EOF'
import os
import re
import sys

workdir, allowed_file = sys.argv[1:]
problems = []
try:
    workflows = sorted(f for f in os.listdir(workdir) if f.endswith((".yml", ".yaml")))
    allowed_lines = open(allowed_file, encoding="utf-8").read().splitlines()
except OSError as e:
    sys.exit(f"error: cannot read {e.filename}: {e.strerror}")
if not workflows:
    problems.append(f"{workdir}: no workflows")
allowed = {}
for number, line in enumerate(allowed_lines, 1):
    words = line.split("#", 1)[0].split(None, 3)
    if not words:
        continue
    if len(words) < 4:
        problems.append(f"{allowed_file}:{number}: want WORKFLOW JOB PERMISSION REASON, got {line.strip()!r}")
    else:
        allowed[tuple(words[:3])] = number
used = set()
PIN = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}\s+#\s*\S+")

for name in workflows:
    path = os.path.join(workdir, name)
    lines = open(path, encoding="utf-8").read().splitlines()
    code = [(n, l) for n, l in enumerate(lines, 1) if l.strip() and not l.lstrip().startswith("#")]
    if not any(re.match(r"^permissions:\s*\{\}\s*$", l) for _, l in code):
        problems.append(f"{path}: no top-level permissions: {{}}")
    for n, l in code:
        if re.search(r"\bpull_request_target\b", l.split(" #", 1)[0]):
            problems.append(f"{path}:{n}: pull_request_target runs with the base repository's secrets")
        m = re.match(r"^\s*(?:- )?uses:\s*(\S.*)$", l)
        if m and not m[1].startswith("./") and not PIN.match(m[1]):
            problems.append(f"{path}:{n}: uses: {m[1]!r} is not pinned to a 40-hex commit with a # version comment")
    jobs, current, top, grants = {}, None, None, False
    for n, l in code:
        indent = len(l) - len(l.lstrip())
        if indent <= 4:
            grants = False
        if indent == 0:
            top, current = l.split(":", 1)[0], None
        elif top == "jobs" and indent == 2:
            current = l.strip().rstrip(":")
            jobs[current] = {"line": n, "permissions": False, "timeout": False, "grants": []}
        elif top == "jobs" and current and indent == 4:
            key, _, value = l.strip().partition(":")
            value = value.strip()
            if key == "permissions":
                jobs[current]["permissions"] = True
                grants = not value
                if value not in ("", "{}"):
                    jobs[current]["grants"].append((n, value))
            elif key == "timeout-minutes" and value:
                jobs[current]["timeout"] = True
        elif grants and indent == 6:
            jobs[current]["grants"].append((n, l.strip()))
    if not jobs:
        problems.append(f"{path}: no jobs")
    for job_name, job in jobs.items():
        where = f"{path}:{job['line']}: job {job_name}"
        if not job["permissions"]:
            problems.append(f"{where} has no permissions:")
        if not job["timeout"]:
            problems.append(f"{where} has no timeout-minutes:")
        for n, grant in job["grants"]:
            if "write" not in grant:
                continue
            key = (name, job_name, grant.replace(" ", ""))
            if key in allowed:
                used.add(key)
            else:
                problems.append(f"{path}:{n}: job {job_name} grants {grant!r} with no reason in {os.path.basename(allowed_file)}")
problems += [
    f"{allowed_file}:{number}: {' '.join(key)} is no longer granted: delete the line"
    for key, number in allowed.items()
    if key not in used
]
for p in problems:
    print(f"error: workflows: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
