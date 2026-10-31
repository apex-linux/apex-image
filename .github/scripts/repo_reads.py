# SPDX-License-Identifier: GPL-3.0-or-later
"""The repository files a shell script sources, runs or reads, for vm-paths-check.sh and g4-harness-check.sh."""

import os
import re
import subprocess
import sys


class Repo:
    def __init__(self, root):
        self.root = root
        out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, check=True).stdout
        self.tracked = set(out.split())
        self.dirs = {os.path.dirname(f) for f in self.tracked}
        for d in list(self.dirs):
            while d:
                self.dirs.add(d)
                d = os.path.dirname(d)

    def read(self, path):
        try:
            return open(os.path.join(self.root, path), encoding="utf-8", errors="replace").read().splitlines()
        except OSError as e:
            sys.exit(f"error: cannot read {e.filename}: {e.strerror}")


def allow_lines(repo, path, problems):
    allowed = {}
    for number, line in enumerate(repo.read(path), 1):
        words = line.split("#", 1)[0].split(None, 2)
        if not words:
            continue
        if len(words) < 3:
            problems.append(f"{path}:{number}: want READER PATH REASON, got {line.strip()!r}")
        else:
            allowed[words[0], words[1]] = number
    return allowed


TOP = r"(?:\.github|tools|image|crates|tests|packaging|docs)/[\w./*${}\[\]-]*|components\.lock|Cargo\.(?:lock|toml)|Justfile"
PREFIX = r"(?:\"?\$\{?(?:APEX_ROOT|checkout|ROOT|root)\}?/|\$\(dirname[^)]*\)/(?:\.\./)*)"
REF = re.compile(rf"(?:(?<=[\s\"'=<(;|&`]){PREFIX}?|{PREFIX}|^)({TOP})")
MESSAGE = re.compile(r"""^\s*(?:echo|printf|die|log|warn|note|notice|usage|flunk|fail|diag_block|error|info)\b|::(?:error|warning|notice)""")
BESIDE = re.compile(r"\$\(dirname[^)]*\)\"?/((?:\.\./)*[\w.-][\w./-]*)")
CASE = re.compile(r"^\s*[^()#]*[^(]\)\s*(?:;;|return\b|$)")


def strip(line):
    if MESSAGE.search(line):
        line = re.sub(r"\"[^\"]*\"|'[^']*'", "", line)
    return re.sub(r"(^|\s)#.*$", "", line)


def references(path, numbered):
    heredoc, quoted, cases, depth = None, False, 0, 0
    shell = not path.endswith(".py")
    for number, line in numbered:
        if heredoc:
            if line.strip() == heredoc:
                heredoc = None
                continue
            if quoted:
                continue
        elif shell:
            m = re.search(r"(?<!<)<<(?!<)-?\s*(['\"]?)(\w+)\1", line)
            if m and not re.search(r"python3|bash|sh\b|awk|jq", line.split("<<")[0]):
                heredoc, quoted = m[2], bool(m[1])
        text = strip(line)
        # A case pattern ends in ")", and so does a multi-line $(...)'s last line.
        pattern = shell and cases > 0 and depth == 0 and CASE.match(text)
        cases += len(re.findall(r"\bcase\b.*\bin\b", text)) - len(re.findall(r"\besac\b", text))
        depth = max(0, depth + text.count("(") - text.count(")"))
        if pattern:
            continue
        for m in REF.finditer(text):
            yield number, m[1].rstrip(".,;:)\"'")
        for m in BESIDE.finditer(text):
            if not m[1].strip("./"):
                continue
            near = os.path.normpath(os.path.join(os.path.dirname(path), m[1].rstrip(".,;:)\"'")))
            if near not in (".", "") and not near.startswith(".."):
                yield number, near


TEMPLATE = re.compile(r"\$\{[^}]*\}|\$\w+|\*|\[[^\]]*\]|\{[^}]*\}")


def expand(repo, token):
    """The tracked files a templated TOKEN can name: each template part stands for one path segment's text."""
    parts = TEMPLATE.split(token)
    pattern = re.compile("[^/]*".join(map(re.escape, parts)) + "(?:/.*)?")
    return sorted(f for f in repo.tracked if pattern.fullmatch(f))


def walk(repo, queue, covered, allowed, covers, under, problems):
    """Follow QUEUE's (path, where) pairs; return {reached path: where} and {allow line used: its read}."""
    seen, used = {}, {}
    while queue:
        token, where = queue.pop(0)
        reader = where.split(":")[0]
        static = re.split(r"[$*\[{]", token)[0]
        if token in repo.tracked:
            if token not in seen:
                seen[token] = where
                lines = repo.read(token)
                if token.endswith((".sh", ".py")) or lines[:1] and lines[0].startswith("#!"):
                    for number, ref in references(token, enumerate(lines, 1)):
                        queue.append((ref, f"{token}:{number}"))
            ok = covered(token)
        elif static != token:
            matches = expand(repo, token)
            if matches and (reader, token) not in allowed:
                queue += [(m, where) for m in matches]
                continue
            base = static if static.endswith("/") else os.path.dirname(static)
            base = base.rstrip("/")
            ok = covered(base) or (base not in repo.dirs and base not in repo.tracked)
            if not ok and (reader, token) not in allowed:
                problems.append(f"{where}: unresolvable path {token!r}: its static part {base} is not under {under}")
                continue
        elif token in repo.dirs:
            ok = covered(token)
            # A directory's line excuses one read: a second one may list or read any file in it.
            if (reader, token) in used and used[reader, token] != where:
                problems.append(f"{where}: reads {token} again; its allow line excuses only {used[reader, token]}")
                continue
        else:
            continue
        if (reader, token) in allowed:
            used.setdefault((reader, token), where)
            continue
        if not ok:
            problems.append(f"{where}: reads {token}, which {covers}")
    return seen, used
