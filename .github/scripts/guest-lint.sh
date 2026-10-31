#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

guest-lint.sh QUALIFY ALLOWED

Parses the code QUALIFY (qualify.sh) runs in the guest, which no hosted check otherwise reads:
each vm_ssh command (local expansions stubbed with X, qualify.sh's literal arrays expanded),
each script a function prints for bash -s or sh -s (bash -n or dash -n, and shellcheck at
--severity=style), and each python3 -c string. A shellcheck finding passes only with an exact
FUNCTION SCnnnn REASON line in ALLOWED; a command it cannot read fails.

  guest-lint.sh QUALIFY ALLOWED    exit 0 when all of it parses
EOF
    exit 2
}

(($# == 2)) || usage
exec python3 - "$@" <<'EOF'
import os
import re
import shlex
import subprocess
import sys
import tempfile

path, allowed_file = sys.argv[1:]
try:
    src = open(path, encoding="utf-8").read()
    allowed_lines = open(allowed_file, encoding="utf-8").read().splitlines()
except OSError as e:
    sys.exit(f"error: cannot read {e.filename}: {e.strerror}")
lines = src.replace("\\\n", "  ").split("\n")
problems = []

KNOWN = {}
for m in re.finditer(r"^readonly (\w+)=\((.*?)\)$", src, re.M | re.S):
    try:
        KNOWN[m[1]] = " ".join(shlex.split(m[2], comments=True))
    except ValueError:
        pass
for m in re.finditer(r"^readonly (\w+)=([\w./:-]+)$", src, re.M):
    KNOWN[m[1]] = m[2]


def expansion(inner):
    m = re.fullmatch(r"(\w+)(\[[*@]\])?", inner)
    if m and m[1] in KNOWN:
        return KNOWN[m[1]]
    return "X1 X2" if m and m[2] else "X"


def stub(text, quote):
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text) and text[i + 1] in "$`\\" + quote:
            out.append(text[i + 1])
            i += 2
            continue
        if c == "$" and i + 1 < len(text):
            j = i + 1
            if text[j] in "{(":
                depth, close = 0, {"{": "}", "(": ")"}[text[j]]
                for k in range(j, len(text)):
                    if text[k] == text[j]:
                        depth += 1
                    elif text[k] == close:
                        depth -= 1
                        if depth == 0:
                            break
                else:
                    return None
                out.append(expansion(text[j + 1 : k]) if text[j] == "{" else "X")
                i = k + 1
                continue
            m = re.match(r"[A-Za-z_]\w*|[0-9@*#?$!-]", text[j:])
            if m:
                out.append(expansion(m[0]))
                i = j + m.end()
                continue
        out.append(c)
        i += 1
    return "".join(out)


def quoted(text, q):
    i = 1
    while i < len(text):
        if text[i] == "\\" and q == '"': i += 2; continue
        if text[i] == q: return text[1:i]
        i += 1
    return None

def check(where, code, shell):
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(code + "\n")
    r = subprocess.run([shell, "-n", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    if r.returncode:
        problems.append(f"{where}: {shell} -n: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'syntax error'}")

def heredoc(fn):
    m = re.search(rf"^{fn}\(\) \{{\n(.*?)\n\}}\n", src, re.M | re.S)
    if not m: return None, None
    h = re.search(r"cat <<('?)EOF\1\n(.*?)\nEOF$", m[1], re.S)
    if not h: return None, None
    return h[2], bool(h[1])

allowed, used = {}, set()
for number, line in enumerate(allowed_lines, 1):
    words = line.split("#", 1)[0].split(None, 2)
    if not words:
        continue
    if len(words) < 3 or not re.fullmatch(r"SC\d{4}", words[1]):
        problems.append(f"{allowed_file}:{number}: want FUNCTION SCnnnn REASON, got {line.strip()!r}")
    else:
        allowed[words[0], words[1]] = number


def shellcheck(fn, code, shell):
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(f"#!/bin/{shell}\n{code}\n")
    r = subprocess.run(["shellcheck", "--severity=style", "-s", shell, "-f", "gcc", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    for out in r.stdout.splitlines():
        m = re.match(r".*?:(\d+):\d+: \w+: (.*) \[(SC\d+)\]$", out)
        if not m:
            continue
        if (fn, m[3]) in allowed:
            used.add((fn, m[3]))
        else:
            problems.append(f"{path} {fn}(), its line {int(m[1]) - 1}: {m[3]}: {m[2]}")


calls, scripts = 0, {}
for n, line in enumerate(lines, 1):
    if line.lstrip().startswith("#") or re.match(r"^\s*vm_ssh\(\)", line):
        continue
    fed = re.search(r"\b(bash|sh)\b[^<]*-s\b.*<\s*<\((\w+)\)", line)
    if fed:
        scripts.setdefault(fed[2], (f"{path}:{n}", fed[1]))
    for m in re.finditer(r"\bvm_ssh\s+(.*)", line):
        arg, where = m[1], f"{path}:{n}"
        calls += 1
        if arg[0] in "\"'":
            body = quoted(arg, arg[0])
            if body is None:
                problems.append(f"{where}: cannot find the end of vm_ssh's quoted command")
                continue
            code = stub(body, '"') if arg[0] == '"' else body
            if code is None:
                problems.append(f"{where}: cannot stub vm_ssh's command")
                continue
            check(where, code, "bash")
            continue
        words = re.match(r"([^|&;<>)]*)", arg)[1].split()
        if words[:2] in (["bash", "-s"], ["sh", "-s"]):
            if not fed:
                problems.append(f"{where}: {words[0]} -s with no script fed from a function")
        elif any("$" in w and w != '"$@"' for w in words):
            problems.append(f"{where}: vm_ssh's command is built at run time ({' '.join(words)}): it cannot be checked")
        else:
            check(where, " ".join(words), "bash")
for fn, (where, shell) in sorted(scripts.items()):
    body, literal = heredoc(fn)
    if body is None:
        problems.append(f"{where}: no cat <<EOF body in {fn}()")
        continue
    code = body if literal else stub(body, "")
    check(f"{where} ({fn})", code, "bash" if shell == "bash" else "dash")
    shellcheck(fn, code, shell)
for m in re.finditer(r"python3 -c \"\$(\w+)\"", src):
    pm = re.search(rf"^readonly {m[1]}='(.*?)'$", src, re.M | re.S)
    if not pm:
        problems.append(f"{path}: python3 -c \"${m[1]}\" with no readonly {m[1]}='...'")
        continue
    try:
        compile(pm[1], m[1], "exec")
    except SyntaxError as e:
        problems.append(f"{path}: {m[1]}, its line {e.lineno}: {e.msg}")
if not calls:
    problems.append(f"{path}: no vm_ssh call")
problems += [f"{allowed_file}:{n}: {f} {c} no longer fires: delete the line" for (f, c), n in allowed.items() if (f, c) not in used]
for p in problems:
    print(f"error: guest code: {p}", file=sys.stderr)
print(f"guest code: {calls} vm_ssh commands, {len(scripts)} fed scripts and the python3 -c strings of {path} parse")
sys.exit(1 if problems else 0)
EOF
