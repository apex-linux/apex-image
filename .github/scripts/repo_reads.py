# SPDX-License-Identifier: GPL-3.0-or-later
"""The repository files a shell script sources, runs or reads, for vm-paths-check.sh and g4-harness-check.sh."""

import ast
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

    def source(self, path):
        try:
            return open(os.path.join(self.root, path), "rb").read()
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
HERE = re.compile(r"os\.path\.dirname\((?:os\.path\.(?:abs|real)path\()?__file__\)?\)|Path\(__file__\)(?:\.resolve\(\))?\.parent")


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


UNRESOLVED, UNPARSED = "\0", "\1"


def module_files(base, dotted):
    """The files under BASE that importing DOTTED runs: each package's __init__.py, then the module."""
    parts = [p for p in dotted.split(".") if p]
    for i in range(1, len(parts) + 1):
        yield os.path.normpath(os.path.join(base, *parts[:i], "__init__.py"))
    if parts:
        yield os.path.normpath(os.path.join(base, *parts) + ".py")


def joined_to_here(node):
    """The path NODE builds on __file__'s directory with string constants alone, or None."""
    def here(n):
        return isinstance(n, (ast.Call, ast.Attribute)) and HERE.fullmatch(ast.unparse(n)) is not None

    def text(n):
        return n.value if isinstance(n, ast.Constant) and isinstance(n.value, str) else None

    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Div, ast.Add)) and here(node.left) and text(node.right):
        return text(node.right)
    if isinstance(node, ast.Call) and ast.unparse(node.func) == "os.path.join" and node.args and here(node.args[0]):
        rest = [text(a) for a in node.args[1:]]
        return os.path.join(*rest) if rest and None not in rest else None
    if isinstance(node, ast.JoinedStr) and len(node.values) == 2:
        first, second = node.values
        if isinstance(first, ast.FormattedValue) and here(first.value) and text(second):
            return text(second)
    return None


def python_reads(path, source, tracked):
    """Modules PATH's SOURCE imports, files it joins to __file__, and __file__ uses it cannot follow."""
    lines = re.split(r"\r\n|\r|\n", source.decode("utf-8", "replace"))
    try:
        return dict.fromkeys(python_reads_of(path, source, lines, tracked))
    except RecursionError:
        return {(1, UNPARSED + f"{path} nests too deeply for the walk"): None}


def import_bases(path, level, tracked):
    """Where a module PATH imports at LEVEL is looked for: beside it, or from its top package's parent."""
    here = os.path.dirname(path)
    if level:
        return [os.path.normpath(os.path.join(here, *[".."] * (level - 1)))]
    top = here
    while top and os.path.join(top, "__init__.py") in tracked:
        top = os.path.dirname(top)
    return [here] if top == here else [here, top]


def python_reads_of(path, source, lines, tracked):
    here = os.path.dirname(path)
    try:
        tree = ast.parse(source, path)
    except SyntaxError as e:
        yield e.lineno or 1, UNPARSED + f"{path} does not parse ({e.msg})"
        return
    nodes = list(ast.walk(tree))
    followed = set()
    for node in nodes:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            level = getattr(node, "level", 0)
            module = getattr(node, "module", None) or ""
            for base in import_bases(path, level, tracked):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        for f in module_files(base, alias.name):
                            yield node.lineno, os.path.normpath(f)
                    continue
                for f in module_files(base, module):
                    yield node.lineno, os.path.normpath(f)
                for alias in node.names:
                    if alias.name not in ("*", "__file__"):
                        for f in module_files(base, f"{module}.{alias.name}"):
                            yield node.lineno, os.path.normpath(f)
            if isinstance(node, ast.ImportFrom) and any(alias.name == "__file__" for alias in node.names):
                yield node.lineno, UNRESOLVED + lines[node.lineno - 1].strip()
        else:
            name = joined_to_here(node)
            if name is not None:
                followed |= {id(n) for n in ast.walk(node)}
                yield node.lineno, os.path.normpath(os.path.join(here, name.lstrip("/")))
    for node in nodes:
        named = isinstance(node, ast.Name) and node.id == "__file__"
        named = named or isinstance(node, ast.Attribute) and node.attr == "__file__"
        if named and id(node) not in followed:
            yield node.lineno, UNRESOLVED + lines[node.lineno - 1].strip()


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
        if token.startswith(UNPARSED):
            problems.append(f"{where}: {token[1:]}, so the walk cannot tell what it reads")
            continue
        if token.startswith(UNRESOLVED):
            if (reader, "__file__") in allowed:
                first = used.setdefault((reader, "__file__"), where)
                if first != where:
                    problems.append(f"{where}: uses __file__ again; its allow line excuses only {first}")
                continue
            problems.append(
                f"{where}: cannot tell what {token[1:]!r} reads: join a string to __file__ on that line,"
                f" or excuse this one use with the allow line '{reader} __file__ REASON'"
            )
            continue
        token = token.rstrip("/") or token
        static = re.split(r"[$*\[{]", token)[0]
        if token in repo.tracked:
            if token not in seen:
                seen[token] = where
                if token.endswith(".py"):
                    source = repo.source(token)
                    lines = re.split(r"\r\n|\r|\n", source.decode("utf-8", "replace"))
                    refs = list(python_reads(token, source, repo.tracked)) + list(references(token, enumerate(lines, 1)))
                else:
                    lines = repo.read(token)
                    shell = token.endswith(".sh") or lines[:1] and lines[0].startswith("#!")
                    refs = references(token, enumerate(lines, 1)) if shell else []
                for number, ref in refs:
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
