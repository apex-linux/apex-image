#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

vm-paths-check.sh ROOT

Checks that vm.yml's push paths in the checkout ROOT cover what a VM run reads. It starts at
each listed file and each repository path vm.yml's run: steps name, and follows what every
reached script sources, runs or reads as data. A read that no path covers fails, as does a
dynamic path whose static part no path covers, unless .github/scripts/vm-paths-allowed.txt
gives that reader and path with a reason. tools/runner/README.md's "What a run does" must
name each path, and no file vm.yml does not list.

  vm-paths-check.sh ROOT    exit 0 when the paths cover every read
EOF
    exit 2
}

(($# == 1)) || usage
exec python3 - "$1" <<'EOF'
import os
import re
import subprocess
import sys

root = sys.argv[1]
workflow, allowed_file, readme = ".github/workflows/vm.yml", ".github/scripts/vm-paths-allowed.txt", "tools/runner/README.md"
tracked = set(subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, check=True).stdout.split())
tracked_dirs = {os.path.dirname(f) for f in tracked}
for d in list(tracked_dirs):
    while d:
        tracked_dirs.add(d)
        d = os.path.dirname(d)
problems = []


def read(path):
    try:
        return open(os.path.join(root, path), encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        sys.exit(f"error: cannot read {e.filename}: {e.strerror}")


lines = read(workflow)
paths, steps, inside = [], [], None
for number, line in enumerate(lines, 1):
    if re.match(r"^    paths:\s*$", line):
        inside = "paths"
        continue
    if inside == "paths":
        m = re.match(r"^      - (\S+)\s*$", line)
        if m:
            paths.append(m[1])
            continue
        if line.strip().startswith("#"):
            continue
        inside = None
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
    sys.exit(f"error: {workflow} has no on.push.paths")


def covered(p):
    return any(p == q or (q.endswith("/**") and (p + "/").startswith(q[:-2])) for q in paths)


allowed = {}
for number, line in enumerate(read(allowed_file), 1):
    words = line.split("#", 1)[0].split(None, 2)
    if not words:
        continue
    if len(words) < 3:
        problems.append(f"{allowed_file}:{number}: want READER PATH REASON, got {line.strip()!r}")
    else:
        allowed[words[0], words[1]] = number
used = set()

TOP = r"(?:\.github|tools|image|crates|tests|packaging|docs)/[\w./*${}\[\]-]*|components\.lock|Cargo\.(?:lock|toml)|Justfile"
PREFIX = r"(?:\"?\$\{?(?:APEX_ROOT|checkout|ROOT|root)\}?/|\$\(dirname[^)]*\)/(?:\.\./)*)"
REF = re.compile(rf"(?:(?<=[\s\"'=<(;|&`]){PREFIX}?|{PREFIX}|^)({TOP})")
MESSAGE = re.compile(r"""^\s*(?:echo|printf|die|log|warn|note|usage|flunk|error|info)\b|::(?:error|warning|notice)""")
BESIDE = re.compile(r"\$\(dirname[^)]*\)\"?/((?:\.\./)*[\w.-][\w./-]*)")
CASE = re.compile(r"^\s*[^()#]*[^(]\)\s*(?:;;|return\b|$)")


def strip(line):
    if MESSAGE.search(line):
        line = re.sub(r"\"[^\"]*\"|'[^']*'", "", line)
    return re.sub(r"(^|\s)#.*$", "", line)


def references(path, numbered):
    heredoc = None
    for number, line in numbered:
        if heredoc:
            if line.strip() == heredoc:
                heredoc = None
            continue
        m = re.search(r"<<-?\s*'?\"?(\w+)'?\"?", line)
        if m and not re.search(r"python3|bash|sh\b|awk|jq", line.split("<<")[0]):
            heredoc = m[1]
        text = strip(line)
        if CASE.match(text):
            continue
        for m in REF.finditer(text):
            yield number, m[1].rstrip(".,;:)\"'")
        for m in BESIDE.finditer(text):
            if not m[1].strip("./"):
                continue
            near = os.path.normpath(os.path.join(os.path.dirname(path), m[1].rstrip(".,;:)\"'")))
            if near not in (".", "") and not near.startswith(".."):
                yield number, near


seen, queue = {}, [(p, f"{workflow} paths") for p in paths if p in tracked]
for number, token in references(workflow, steps):
    queue.append((token, f"{workflow}:{number}"))
while queue:
    token, where = queue.pop(0)
    reader = where.split(":")[0]
    static = re.split(r"[$*\[{]", token)[0].rstrip("/")
    if token in tracked:
        if token not in seen:
            seen[token] = where
            if token.endswith(".sh") or read(token)[:1] and read(token)[0].startswith("#!"):
                for number, ref in references(token, enumerate(read(token), 1)):
                    queue.append((ref, f"{token}:{number}"))
        ok = covered(token)
    elif static != token:
        ok = covered(static) or (static not in tracked_dirs and static not in tracked)
        if not ok and (reader, token) not in allowed:
            problems.append(f"{where}: unresolvable path {token!r}: its static part {static} is not under a {workflow} path")
            continue
    elif token in tracked_dirs:
        ok = covered(token)
    else:
        continue
    if (reader, token) in allowed:
        used.add((reader, token))
        continue
    if not ok:
        problems.append(f"{where}: reads {token}, which no {workflow} path covers")
problems += [f"{allowed_file}:{n}: {r} {t} is no longer an uncovered read: delete the line" for (r, t), n in allowed.items() if (r, t) not in used]
text = "\n".join(read(readme))
section = re.search(r"on a push to `main` that touches(.*?)Each such push", text, re.S)
if not section:
    problems.append(f"{readme}: no \"What a run does\" list of the paths a push to main runs on")
else:
    named = set(re.findall(r"`([^`\s]+)`|\b([\w-]+\.sh)\b", section[1]))
    named = {a or b for a, b in named if not (a or b).endswith("/") and ("." in (a or b) or "/" in (a or b))}
    problems += [f"{readme}: \"What a run does\" does not name {p}" for p in paths if p not in named and os.path.basename(p) not in named]
    problems += [
        f"{readme}: \"What a run does\" names {n}, which no {workflow} path is"
        for n in sorted(named)
        if n not in paths and n not in {os.path.basename(p) for p in paths}
    ]
for path in sorted(seen):
    print(f"reached {path} (from {seen[path]})")
for p in sorted(set(problems)):
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
