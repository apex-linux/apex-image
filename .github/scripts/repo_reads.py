# SPDX-License-Identifier: GPL-3.0-or-later
"""The repository files a shell script sources, runs or reads, for vm-paths-check.sh and g4-harness-check.sh."""

import ast
import hashlib
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


def strip(line):
    if MESSAGE.search(line):
        line = re.sub(r"\"[^\"]*\"|'[^']*'", "", line)
    return re.sub(r"(^|\s)#.*$", "", line)


def references(path, numbered, python=None):
    heredoc, quoted, cases, depth = None, False, 0, 0
    shell = not (path.endswith(".py") if python is None else python)
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
LINES = re.compile(r"\r\n|\r|\n")
EXTENDS = {"joinpath", "with_suffix", "with_name", "with_stem"}


def module_files(base, dotted):
    """The files under BASE that importing DOTTED runs: each package's __init__.py, then the module."""
    parts = [p for p in dotted.split(".") if p]
    for i in range(1, len(parts) + 1):
        yield os.path.normpath(os.path.join(base, *parts[:i], "__init__.py"))
    if parts:
        yield os.path.normpath(os.path.join(base, *parts) + ".py")


def text(node):
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


class Python:
    """What one piece of Python reads: modules it imports, files it builds on __file__, uses it cannot follow.

    EMBEDDED code runs from a shell script (python3 -c, python3 -): there __file__ is not defined, so it reads nothing."""

    def __init__(self, path, lines, tracked, source_of, embedded=False):
        self.path, self.lines, self.tracked, self.source_of, self.embedded = path, lines, tracked, source_of, embedded
        self.here = os.path.dirname(path)
        self.aliases, self.parents, self.bases, self.built = {}, {}, [], {}

    def qual(self, node):
        if isinstance(node, ast.Name):
            return self.aliases.get(node.id, node.id)
        if isinstance(node, ast.Attribute):
            value = self.qual(node.value)
            return value and f"{value}.{node.attr}"
        return None

    def is_file(self, node):
        return not self.embedded and isinstance(node, ast.Name) and node.id == "__file__"

    def file_path(self, node):
        """NODE is a pathlib path of __file__: Path(__file__), maybe .resolve() or .absolute()."""
        if not isinstance(node, ast.Call):
            return False
        if self.qual(node.func) in ("pathlib.Path", "pathlib.PurePath", "Path", "PurePath") and len(node.args) == 1:
            return self.is_file(node.args[0])
        func = node.func
        return isinstance(func, ast.Attribute) and func.attr in ("resolve", "absolute") and self.file_path(func.value)

    def here_dir(self, node):
        if isinstance(node, ast.Attribute):
            return node.attr == "parent" and self.file_path(node.value)
        if not isinstance(node, ast.Call) or self.qual(node.func) != "os.path.dirname" or len(node.args) != 1:
            return False
        arg = node.args[0]
        if isinstance(arg, ast.Call) and self.qual(arg.func) in ("os.path.abspath", "os.path.realpath") and len(arg.args) == 1:
            arg = arg.args[0]
        return self.is_file(arg)

    def path_of(self, node):
        """The path NODE builds under __file__'s directory from string constants alone ("" for the directory), or None."""
        if id(node) not in self.built:
            self.built[id(node)] = self.build(node)
        return self.built[id(node)]

    def build(self, node):
        # A + or / chain is walked down its left side in a loop: a long one would overflow the stack.
        steps = []
        while isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Div, ast.Add)) and id(node) not in self.built:
            steps.append(node)
            node = node.left
        if steps:
            built = self.path_of(node)
            for step in reversed(steps):
                right = text(step.right)
                built = None if built is None or right is None else built + right if isinstance(step.op, ast.Add) else os.path.join(built, right)
                self.built[id(step)] = built
            return built
        if self.here_dir(node):
            return ""
        if isinstance(node, ast.Call):
            func, args = node.func, node.args
            if self.qual(func) == "os.path.join" and args:
                first, rest = self.path_of(args[0]), [text(a) for a in args[1:]]
                return None if first is None or None in rest else os.path.join(first, *rest)
            if isinstance(func, ast.Attribute) and func.attr in EXTENDS:
                base, rest = self.path_of(func.value), [text(a) for a in args]
                if base is None or None in rest or not rest:
                    return None
                if func.attr == "joinpath":
                    return os.path.join(base, *rest)
                if func.attr == "with_suffix":
                    return os.path.splitext(base)[0] + rest[0]
                if func.attr == "with_name":
                    return os.path.join(os.path.dirname(base), rest[0])
                return os.path.join(os.path.dirname(base), rest[0] + os.path.splitext(base)[1])
        if isinstance(node, ast.JoinedStr):
            parts = []
            for value in node.values:
                part = self.path_of(value.value) if isinstance(value, ast.FormattedValue) else text(value)
                if part is None or isinstance(value, ast.FormattedValue) and (value.format_spec or value.conversion != -1):
                    return None
                parts.append(part)
            return "".join(parts) if any(isinstance(v, ast.FormattedValue) for v in node.values) else None
        return None

    def extends(self, node):
        """NODE's parent builds a longer path on it."""
        parent = self.parents.get(id(node))
        if isinstance(parent, ast.BinOp) and parent.left is node:
            return True
        if isinstance(parent, ast.Attribute) and parent.attr in EXTENDS:
            return True
        if isinstance(parent, ast.Call) and self.qual(parent.func) == "os.path.join" and parent.args[:1] == [node]:
            return True
        return isinstance(parent, ast.FormattedValue)

    def import_bases(self, level):
        """Where a module imported at LEVEL is looked for: beside the code, its top package's parent, sys.path."""
        if level:
            return [os.path.normpath(os.path.join(self.here, *[".."] * (level - 1)))]
        top = self.here
        while top and os.path.join(top, "__init__.py") in self.tracked:
            top = os.path.dirname(top)
        bases = [self.here, top] + self.bases + ([""] if self.embedded else [])
        return list(dict.fromkeys(os.path.normpath(b) if b else "" for b in bases))

    def star_names(self, base, module):
        """The names a package's __init__.py lists in __all__, which `from PACKAGE import *` imports."""
        init = os.path.normpath(os.path.join(base, *module.split("."), "__init__.py"))
        if init not in self.tracked:
            return []
        try:
            tree = ast.parse(self.source_of(init), init)
        except (SyntaxError, RecursionError):
            return []
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets):
                if isinstance(node.value, (ast.List, ast.Tuple)):
                    return [n for n in map(text, node.value.elts) if n]
        return []

    def unresolved(self, node, seen):
        line = self.lines[node.lineno - 1].strip()
        digest = hashlib.sha256(line.encode()).hexdigest()[:8]
        seen[digest] = seen.get(digest, 0) + 1
        key = f"__file__@{digest}" + (f".{seen[digest]}" if seen[digest] > 1 else "")
        return node.lineno, UNRESOLVED + key + UNRESOLVED + line

    def reads(self, tree):
        nodes = list(ast.walk(tree))
        for node in nodes:
            for child in ast.iter_child_nodes(node):
                self.parents[id(child)] = node
        for node in nodes:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.asname:
                        self.aliases[alias.asname] = alias.name
            elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
                for alias in node.names:
                    self.aliases[alias.asname or alias.name] = f"{node.module}.{alias.name}"
        for node in nodes:
            if isinstance(node, ast.Call) and self.qual(node.func) in ("sys.path.insert", "sys.path.append") and node.args:
                where = self.path_of(node.args[-1])
                if where is not None:
                    self.bases.append(os.path.join(self.here, where.lstrip("/")))
                elif text(node.args[-1]) is not None:
                    self.bases += [os.path.join(self.here, text(node.args[-1])), text(node.args[-1])]
        followed, seen = set(), {}
        for node in nodes:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                yield from self.imports(node)
                continue
            if isinstance(node, ast.Call) and node.args and text(node.args[0]) is not None:
                yield from self.dynamic(node, text(node.args[0]))
            built = self.path_of(node)
            if built is None or self.extends(node) and self.path_of(self.parents[id(node)]) is not None:
                continue
            if built and not self.extends(node):
                followed |= {id(n) for n in ast.walk(node)}
                yield node.lineno, os.path.normpath(os.path.join(self.here, built.lstrip("/")))
        uses = sorted((n for n in nodes if getattr(n, "lineno", None)), key=lambda n: (n.lineno, n.col_offset))
        for node in uses:
            named = isinstance(node, ast.Name) and node.id == "__file__" and id(node) not in followed and not self.embedded
            named = named or isinstance(node, ast.Attribute) and node.attr == "__file__"
            named = named or isinstance(node, ast.ImportFrom) and any(a.name == "__file__" for a in node.names)
            if named:
                yield self.unresolved(node, seen)

    def imports(self, node):
        level = getattr(node, "level", 0)
        module = getattr(node, "module", None) or ""
        for base in self.import_bases(level):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    for f in module_files(base, alias.name):
                        yield node.lineno, f
                continue
            for f in module_files(base, module):
                yield node.lineno, f
            names = [a.name for a in node.names]
            if "*" in names:
                names += self.star_names(base, module)
            for name in names:
                if name not in ("*", "__file__"):
                    for f in module_files(base, f"{module}.{name}"):
                        yield node.lineno, f

    def dynamic(self, node, name):
        """importlib.import_module, __import__ and runpy with a constant: what they load."""
        called = self.qual(node.func)
        if called in ("importlib.import_module", "__import__", "runpy.run_module"):
            for base in self.import_bases(0):
                for f in module_files(base, name):
                    yield node.lineno, f
        elif called == "runpy.run_path":
            for base in dict.fromkeys([self.here, ""]):
                yield node.lineno, os.path.normpath(os.path.join(base, name))


def python_reads(path, lines, tracked, source_of, embedded=False, offset=0):
    """What Python source LINES (PATH's, or embedded in PATH at line OFFSET + 1) reads."""
    try:
        tree = ast.parse("\n".join(lines) if embedded else source_of(path), path)
        reads = list(Python(path, lines, tracked, source_of, embedded).reads(tree))
    except SyntaxError as e:
        reads = [(e.lineno or 1, UNPARSED + f"{path} does not parse on Python {sys.version.split()[0]} ({e.msg})")]
    except RecursionError:
        reads = [(1, UNPARSED + f"{path} nests too deeply for the walk")]
    return dict.fromkeys((number + offset, token) for number, token in reads)


ASSIGNED = re.compile(r"^(?:readonly\s+)?(\w+)='")


def embedded_python(lines):
    """(first line, code lines) for each piece of Python a shell script runs: python3 -c '...',
    python3 -c "$NAME" with NAME='...' in the script, and a heredoc fed to python3 -."""
    text_of = {}
    i = 0
    while i < len(lines):
        m = ASSIGNED.match(lines[i])
        if m:
            body, j = [lines[i][m.end():]], i
            while not body[-1].rstrip().endswith("'") and j + 1 < len(lines):
                j += 1
                body.append(lines[j])
            body[-1] = body[-1].rstrip()[:-1]
            text_of[m[1]] = (i + 1, body)
            i = j
        i += 1
    for number, line in enumerate(lines, 1):
        for m in re.finditer(r"python3?\s+(?:-\w+\s+)*-c\s+(?:'([^']*)'|\"\$\{?(\w+)\}?\")", line):
            if m[1] is not None:
                yield number, [m[1]]
            elif m[2] in text_of:
                yield text_of[m[2]]
        m = re.search(r"python3?\s+(?:-\w+\s+)*-(?:\s|$).*<<-?\s*(['\"]?)(\w+)\1", line)
        if m:
            body = []
            for later in lines[number:]:
                if later.strip() == m[2]:
                    break
                body.append(later)
            yield number + 1, body


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
            if (reader, "__syntax__") in allowed:
                used.setdefault((reader, "__syntax__"), where)
                continue
            problems.append(
                f"{where}: {token[1:]}, so the walk cannot tell what it reads;"
                f" if a newer Python reads it, excuse it with the allow line '{reader} __syntax__ REASON'"
            )
            continue
        if token.startswith(UNRESOLVED):
            key, line = token[1:].split(UNRESOLVED, 1)
            if (reader, key) in allowed:
                used.setdefault((reader, key), where)
                continue
            problems.append(
                f"{where}: cannot tell what {line!r} reads: join a string to __file__ on that line,"
                f" or excuse this use, pinned to that line's text, with the allow line '{reader} {key} REASON'"
            )
            continue
        token = token.rstrip("/") or token
        static = re.split(r"[$*\[{]", token)[0]
        if token in repo.tracked:
            if token not in seen:
                seen[token] = where
                lines = LINES.split(repo.source(token).decode("utf-8", "replace"))
                python = token.endswith(".py") or bool(re.match(r"#!.*\bpython", lines[0]))
                shell = not python and (token.endswith(".sh") or lines[0].startswith("#!"))
                refs = []
                if python:
                    refs += python_reads(token, lines, repo.tracked, repo.source)
                elif shell:
                    for start, code in embedded_python(lines):
                        refs += python_reads(token, code, repo.tracked, repo.source, embedded=True, offset=start - 1)
                if python or shell:
                    refs += references(token, enumerate(lines, 1), python)
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
