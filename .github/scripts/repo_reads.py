# SPDX-License-Identifier: GPL-3.0-or-later
"""The repository files a shell script sources, runs or reads, for vm-paths-check.sh and g4-harness-check.sh."""

import ast
import hashlib
import os
import posixpath
import re
import subprocess
import sys
import warnings


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
WRAPS = {"os.path.abspath", "os.path.realpath", "os.fspath", "str", "pathlib.Path", "pathlib.PurePath", "Path", "PurePath"}
LOADS = {"importlib.import_module", "__import__", "runpy.run_module", "runpy.run_path"}


def module_files(base, dotted):
    """The files under BASE that importing DOTTED runs: each package's __init__.py, then the module."""
    parts = [p for p in dotted.split(".") if p]
    for i in range(1, len(parts) + 1):
        yield posixpath.normpath(posixpath.join(base, *parts[:i], "__init__.py"))
    if parts:
        yield posixpath.normpath(posixpath.join(base, *parts) + ".py")


def text(node):
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


def line_key(kind, line, seen):
    """KIND@HASH of LINE's text, with .N for the Nth such line one reader has."""
    digest = hashlib.sha256(line.encode()).hexdigest()[:8]
    seen[kind, digest] = seen.get((kind, digest), 0) + 1
    return f"{kind}@{digest}" + (f".{seen[kind, digest]}" if seen[kind, digest] > 1 else "")


class Python:
    """What one piece of Python reads: modules it imports, files it builds on __file__, uses it cannot follow.

    RUN is how it runs: "file" (PATH itself), "stdin" (python3 -, where __file__ is "<stdin>" in the
    cwd, the checkout's root) or "c" (python3 -c, where __file__ is not defined and so reads nothing)."""

    def __init__(self, path, lines, tracked, source_of, run, seen):
        self.path, self.lines, self.tracked, self.source_of, self.run, self.seen = path, lines, tracked, source_of, run, seen
        self.file = posixpath.normpath(path) if run == "file" else "<stdin>" if run == "stdin" else None
        self.here = posixpath.dirname(self.file) or "." if self.file else None
        self.aliases, self.parents, self.bases, self.values = {}, {}, [], {}

    def qual(self, node):
        if isinstance(node, ast.Name):
            return self.aliases.get(node.id, node.id)
        if isinstance(node, ast.Attribute):
            value = self.qual(node.value)
            return value and f"{value}.{node.attr}"
        return None

    def value(self, node):
        """The repository path NODE names, built on __file__ from string constants alone, or None."""
        if id(node) not in self.values:
            self.values[id(node)] = self.build(node)
        return self.values[id(node)]

    def build(self, node):
        # A + or / chain is walked down its left side in a loop: a long one would overflow the stack.
        steps = []
        while isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Div, ast.Add)) and id(node) not in self.values:
            steps.append(node)
            node = node.left
        if steps:
            built = self.value(node)
            for step in reversed(steps):
                right = text(step.right)
                if built is not None and right is not None:
                    built = posixpath.normpath(built + right if isinstance(step.op, ast.Add) else posixpath.join(built, right))
                else:
                    built = None
                self.values[id(step)] = built
            return built
        if isinstance(node, ast.Name) and node.id == "__file__":
            return self.file
        if isinstance(node, ast.Attribute) and node.attr == "parent":
            base = self.value(node.value)
            return base and (posixpath.dirname(base) or ".")
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
            base, index = self.value(node.value.value), node.slice
            if base is None or not isinstance(index, ast.Constant) or not isinstance(index.value, int) or index.value < 0:
                return None
            for _ in range(index.value + 1):
                base = posixpath.normpath(posixpath.join(base, ".."))
            return base
        if isinstance(node, ast.JoinedStr):
            parts = []
            for part in node.values:
                built = self.value(part.value) if isinstance(part, ast.FormattedValue) else text(part)
                if built is None or isinstance(part, ast.FormattedValue) and (part.format_spec or part.conversion != -1):
                    return None
                parts.append(built)
            joined = any(isinstance(p, ast.FormattedValue) for p in node.values)
            return posixpath.normpath("".join(parts)) if joined else None
        if not isinstance(node, ast.Call):
            return None
        func, args, called = node.func, node.args, self.qual(node.func)
        if called in WRAPS and args and not node.keywords:
            first, rest = self.value(args[0]), [text(a) for a in args[1:]]
            return None if first is None or None in rest else posixpath.normpath(posixpath.join(first, *rest))
        if called == "os.path.dirname" and len(args) == 1:
            base = self.value(args[0])
            return base and (posixpath.dirname(base) or ".")
        if called == "os.path.join" and args:
            first, rest = self.value(args[0]), [text(a) for a in args[1:]]
            return None if first is None or None in rest else posixpath.normpath(posixpath.join(first, *rest))
        if isinstance(func, ast.Attribute) and func.attr in ("resolve", "absolute") and not args:
            return self.value(func.value)
        if isinstance(func, ast.Attribute) and func.attr in EXTENDS:
            base, rest = self.value(func.value), [text(a) for a in args]
            if base is None or None in rest or not rest:
                return None
            head, name = posixpath.split(base)
            stem, suffix = posixpath.splitext(name)
            built = {
                "joinpath": lambda: posixpath.join(base, *rest),
                "with_suffix": lambda: posixpath.join(head, stem + rest[0]),
                "with_name": lambda: posixpath.join(head, rest[0]),
                "with_stem": lambda: posixpath.join(head, rest[0] + suffix),
            }[func.attr]()
            return posixpath.normpath(built)
        return None

    def builds_on(self, parent, node):
        """PARENT builds a path on NODE, so NODE is only part of what is read."""
        if isinstance(parent, ast.BinOp):
            return parent.left is node
        if isinstance(parent, ast.Attribute):
            return parent.attr in EXTENDS | {"parent", "parents", "resolve", "absolute"}
        if isinstance(parent, ast.Subscript):
            return False
        if isinstance(parent, ast.Call):
            called = self.qual(parent.func)
            return called in WRAPS | {"os.path.dirname"} or called == "os.path.join" and parent.args[:1] == [node]
        return isinstance(parent, ast.FormattedValue)

    def base_only(self, built):
        """BUILT is the script, a directory it sits in, or outside the checkout: a base for later reads."""
        if built == self.file or built.startswith(".."):
            return True
        return built == "." or self.here is not None and (self.here == built or self.here.startswith(built + "/"))

    def import_bases(self, level):
        """Where a module imported at LEVEL is looked for: beside the code, its top package's parent, sys.path."""
        here = posixpath.dirname(self.path) if self.run == "file" else posixpath.dirname(self.path)
        if level:
            return [posixpath.normpath(posixpath.join(here or ".", *[".."] * (level - 1)))]
        top = here
        while top and posixpath.join(top, "__init__.py") in self.tracked:
            top = posixpath.dirname(top)
        bases = [here, top] + self.bases + ([] if self.run == "file" else [""])
        return list(dict.fromkeys(posixpath.normpath(b) if b else "" for b in bases))

    def star_names(self, base, module):
        """The names a package's __init__.py lists in __all__, which `from PACKAGE import *` imports."""
        init = posixpath.normpath(posixpath.join(base, *module.split("."), "__init__.py"))
        if init not in self.tracked:
            return []
        try:
            tree = ast.parse(self.source_of(init), init)
        except (SyntaxError, ValueError, RecursionError):
            return []
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets):
                if isinstance(node.value, (ast.List, ast.Tuple)):
                    return [n for n in map(text, node.value.elts) if n]
        return []

    def unresolved(self, node, kind):
        line = self.lines[node.lineno - 1].strip()
        return node.lineno, UNRESOLVED + line_key(kind, line, self.seen) + UNRESOLVED + line

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
        done = set()
        for node in nodes:
            if isinstance(node, ast.Call) and self.qual(node.func) in ("sys.path.insert", "sys.path.append") and node.args:
                where, constant = self.value(node.args[-1]), text(node.args[-1])
                if where is not None:
                    self.bases.append(where)
                    done |= {id(n) for n in ast.walk(node.args[-1])}
                elif constant is not None:
                    self.bases += [posixpath.join(posixpath.dirname(self.path), constant), constant]
        for node in nodes:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                yield from self.imports(node)
                if isinstance(node, ast.ImportFrom) and any(a.name == "__file__" for a in node.names):
                    yield self.unresolved(node, "__file__")
                continue
            if isinstance(node, ast.Call) and self.qual(node.func) in LOADS:
                yield from self.loads(node)
            if id(node) in done:
                continue
            built = self.value(node)
            if built is None:
                if isinstance(node, ast.Attribute) and node.attr == "__file__" and self.value(node.value) is None:
                    yield self.unresolved(node, "__file__")
                continue
            parent = self.parents.get(id(node))
            if parent is not None and self.builds_on(parent, node) and self.value(parent) is not None:
                continue
            done |= {id(n) for n in ast.walk(node)}
            if parent is not None and self.builds_on(parent, node) or self.base_only(built):
                yield self.unresolved(node, "__file__")
            else:
                yield node.lineno, built

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

    def loads(self, node):
        """importlib.import_module, __import__ and runpy: what they load, by a constant name or path."""
        called = self.qual(node.func)
        named = [k.value for k in node.keywords if k.arg in ("name", "mod_name", "path_name")]
        arg = node.args[0] if node.args else named[0] if named else None
        if arg is None:
            yield self.unresolved(node, "__import__")
            return
        name, built = text(arg), self.value(arg)
        if called == "runpy.run_path" and built is not None:
            yield node.lineno, built
        elif called == "runpy.run_path" and name is not None:
            for base in dict.fromkeys([posixpath.dirname(self.path), ""]):
                yield node.lineno, posixpath.normpath(posixpath.join(base, name))
        elif name is not None:
            for base in self.import_bases(0):
                yield from ((node.lineno, f) for f in module_files(base, name))
        else:
            prefix = text(arg.values[0]) if isinstance(arg, ast.JoinedStr) and arg.values else None
            if prefix and "." in prefix and called != "runpy.run_path":
                package = prefix.rsplit(".", 1)[0]
                for base in self.import_bases(0):
                    yield from ((node.lineno, f) for f in module_files(base, package))
                    under = posixpath.join(base, *package.split(".")) + "/"
                    yield from ((node.lineno, f) for f in sorted(self.tracked) if f.startswith(under) and f.endswith(".py"))
            yield self.unresolved(node, "__import__")


def python_reads(path, lines, tracked, source_of, seen, run="file", offset=0):
    """What Python LINES (PATH itself, or a piece of PATH from its line OFFSET + 1) reads."""
    where = path if run == "file" else f"the Python at {path}:{offset + 1}"
    first = "\n".join(lines) if run == "file" else next((line.strip() for line in lines if line.strip()), "")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(source_of(path) if run == "file" else "\n".join(lines), path)
        reads = list(Python(path, lines, tracked, source_of, run, seen).reads(tree))
    except (SyntaxError, ValueError) as e:
        why = f"{where} does not parse on Python {sys.version.split()[0]} ({getattr(e, 'msg', e)})"
        reads = [(getattr(e, "lineno", None) or 1, UNPARSED + line_key("__syntax__", first, seen) + UNPARSED + why)]
    except RecursionError:
        reads = [(1, UNPARSED + line_key("__syntax__", first, seen) + UNPARSED + f"{where} nests too deeply for the walk")]
    return list(dict.fromkeys((number + offset, token) for number, token in reads))


PROGRAM = r"(?:[\w./-]*/)?python[0-9.]*"
MENTION = re.compile(rf"(?<![\w.-]){PROGRAM}(?![\w-])")
RUNS_AT = re.compile(r"(?:^|[;|&({]|\$\()\s*$")
LOOKS_UP = re.compile(r"(?:\bcommand\s+-v|\btype|\bhash|\bwhich)\s+$")
FLAGS = r"(?:\s+-[A-Zabd-z]+)*"
REDIRECTS = r"(?:\s+(?:-[A-Za-z]+|[0-9]*>>?\s*[\w./$\"{}-]+|[0-9]*>&[0-9]+|&>\s*[\w./$\"{}-]+))*"
BY_NAME = re.compile(rf"{PROGRAM}{FLAGS}\s+-c\s+(?:\"\$\{{?(\w+)\}}?\"|\$\{{?(\w+)\}}?)(?=[\s;|&)]|$)")
BY_LITERAL = re.compile(rf"{PROGRAM}{FLAGS}\s+-c\s+'")
BY_HEREDOC = re.compile(rf"{PROGRAM}{REDIRECTS}\s+-(?:\s+[^<\n]*?)?\s*<<\s*(['\"])(\w+)\1")
BY_SCRIPT = re.compile(rf"{PROGRAM}{FLAGS}\s+(?:\"?\$\{{?(?:APEX_ROOT|checkout|ROOT|root)\}}?/[\w./-]+\"?|[\w./-]+\.py)(?=[\s;|&)]|$)")
BLOCK = re.compile(r"^[ \t]*(?:(?:readonly|local|export|declare(?:[ \t]+-\w+)*)[ \t]+)?(\w+)='", re.M)
SOURCES = re.compile(r"^[ \t]*(?:\.|source)[ \t]+\S", re.M)
LARGEST = 4 << 20


class Script:
    """A shell script's NAME='...' blocks, read the narrow way: one quote to the next, '\\'' unread."""

    def __init__(self, source):
        self.source, self.blocks, self.starts, self.spans = source, {}, set(), []
        for m in BLOCK.finditer(source):
            if any(a <= m.start() < b for a, b in self.spans):
                continue
            end = source.find("'", m.end())
            if end < 0:
                break
            self.spans.append((m.end(), end))
            if not source.startswith("\\'", end + 1):
                self.starts.add(m.start(1))
                line = source.count("\n", 0, m.end()) + 1
                self.blocks.setdefault(m[1], []).append((line, source[m.end():end]))

    def readable(self, name):
        """NAME is set only by blocks the walk read: no NAME+=, NAME="...", NAME=$(...) or one inside a line."""
        assign = rf"(?<![\w$])(?:(?:local|readonly|export|declare(?:\s+-\w+)*)\s+)?(?P<n>{re.escape(name)})(\+?)="
        return all(not m[2] and m.start("n") in self.starts for m in re.finditer(assign, self.source))


def where_in(line, col):
    """"comment" or "quoted" if column COL of LINE is in one, by a one-line scan, else None."""
    quote, i = None, 0
    while i < col:
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t;|&(){}"):
            return "comment"
        i += 1
    return "quoted" if quote else None


def command_text(lines, number):
    """The whole command on line NUMBER, its continuation lines too, and its last line."""
    first = number
    while first > 1 and lines[first - 2].endswith("\\"):
        first -= 1
    last = number
    while last < len(lines) and lines[last - 1].endswith("\\"):
        last += 1
    return "\n".join(line.strip() for line in lines[first - 1:last]), last


def shell_python(repo, path, lines, keys):
    """What the Python a shell script runs reads, and a __python__@ use for each run the walk cannot read."""
    source = "\n".join(lines)
    if not MENTION.search(source):
        return []
    if len(source) > LARGEST:
        return [(1, UNRESOLVED + line_key("__python__", source, keys) + UNRESOLVED + f"{path}, over {LARGEST >> 20} MiB")]
    try:
        return list(python_runs(repo, path, source, lines, keys))
    except Exception as e:  # noqa: BLE001 - anything unforeseen fails closed, naming the script
        said = f"{path} ({type(e).__name__}: {e})"
        return [(1, UNRESOLVED + line_key("__python__", source, keys) + UNRESOLVED + said)]


def python_runs(repo, path, source, lines, keys):
    script, sourced = Script(source), []
    for m in SOURCES.finditer(source):
        number = source.count("\n", 0, m.start()) + 1
        for _, ref in references(path, [(number, lines[number - 1])]):
            if ref in repo.tracked and ref != path:
                sourced.append(Script(repo.source(ref).decode("utf-8", "replace")))
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    done_to, lost = 0, set()
    for m in MENTION.finditer(source):
        at = m.start()
        if at < done_to or any(a <= at < b for a, b in script.spans):
            continue
        number = source.count("\n", 0, at) + 1
        line, col = lines[number - 1], at - starts[number - 1]
        where = where_in(line, col)
        if where == "comment" or where is None and LOOKS_UP.search(line[:col]):
            continue
        command, last = command_text(lines, number)
        piece = None
        if where is None and RUNS_AT.search(line[:col]):
            piece = python_piece(source, source[at:starts[last] - 1], at, number, script, sourced, lines, starts)
        if piece is None:
            if number not in lost:
                lost.add(number)
                yield number, UNRESOLVED + line_key("__python__", command, keys) + UNRESOLVED + command
            continue
        run, first, code, done_to = piece
        if run == "script":
            continue
        yield from python_reads(path, code, repo.tracked, repo.source, keys, run=run, offset=first - 1)


def python_piece(source, rest, at, number, script, sourced, lines, starts):
    """(run, first line, code lines, end offset) for the python run at offset AT, or None if it is not one of
    the forms the walk reads: a repository script, which the line walk follows, -c "$NAME" with NAME='...',
    -c '...', or - with a <<'TERM' heredoc."""
    m = BY_SCRIPT.match(rest)
    if m:
        return "script", number, [], at + m.end()
    m = BY_NAME.match(rest)
    if m:
        name = m[1] or m[2]
        if name in script.blocks:
            if not script.readable(name):
                return None
            defs = script.blocks[name]
            before = [d for d in defs if d[0] < number]
            first, code = before[-1] if before else defs[0]
            return "c", first, LINES.split(code), at + m.end()
        theirs = [s for s in sourced if name in s.blocks]
        if theirs and script.readable(name) and theirs[-1].readable(name):
            return "c", number, LINES.split(theirs[-1].blocks[name][-1][1]), at + m.end()
        return None
    m = BY_LITERAL.match(rest)
    if m:
        opened = at + m.end()
        end = source.find("'", opened)
        if end < 0 or source.startswith("\\'", end + 1):
            return None
        return "c", number, LINES.split(source[opened:end]), end + 1
    m = BY_HEREDOC.match(rest)
    if m:
        first = source.count("\n", 0, at) + 2
        for i in range(first - 1, len(lines)):
            if lines[i] == m[2]:
                return "stdin", first, lines[first - 1:i], starts[i + 1] if i + 1 < len(starts) else len(source)
    return None


TEMPLATE = re.compile(r"\$\{[^}]*\}|\$\w+|\*|\[[^\]]*\]|\{[^}]*\}")


def expand(repo, token):
    """The tracked files a templated TOKEN can name: each template part stands for one path segment's text."""
    parts = TEMPLATE.split(token)
    pattern = re.compile("[^/]*".join(map(re.escape, parts)) + "(?:/.*)?")
    return sorted(f for f in repo.tracked if pattern.fullmatch(f))


def unread(mark, key, said, reader):
    """What a read the walk cannot follow fails with, and how to excuse it."""
    excuse = f"or excuse this use, pinned to that line's text, with the allow line '{reader} {key} REASON'"
    if mark == UNPARSED:
        newer = not said.startswith("the Python at ")
        return f"{said}, so the walk cannot tell what it reads" + (
            f"; if a newer Python reads it, excuse it with the allow line '{reader} {key} REASON'" if newer else "")
    kind = key.split("@")[0]
    if kind == "__import__":
        return f"cannot tell what module {said!r} loads: name it with a constant, {excuse}"
    if kind == "__python__":
        return (f"cannot tell what Python {said!r} runs: give it as -c '...', as -c \"$NAME\" with NAME='...'"
                f" set before it here or in a script this one sources, or as a heredoc; {excuse}")
    return f"cannot tell what {said!r} reads: join a string to __file__ on that line, {excuse}"


def walk(repo, queue, covered, allowed, covers, under, problems):
    """Follow QUEUE's (path, where) pairs; return {reached path: where} and {allow line used: its read}."""
    seen, used = {}, {}
    while queue:
        token, where = queue.pop(0)
        reader = where.split(":")[0]
        if token[:1] in (UNPARSED, UNRESOLVED):
            key, said = token[1:].split(token[0], 1)
            if (reader, key) in allowed:
                used.setdefault((reader, key), where)
                continue
            problems.append(f"{where}: {unread(token[0], key, said, reader)}")
            continue
        token = token.rstrip("/") or token
        static = re.split(r"[$*\[{]", token)[0]
        if token in repo.tracked:
            if token not in seen:
                seen[token] = where
                lines = LINES.split(repo.source(token).decode("utf-8", "replace"))
                python = token.endswith(".py") or bool(re.match(r"#!.*\bpython", lines[0]))
                shell = not python and (token.endswith(".sh") or lines[0].startswith("#!"))
                refs, keys = [], {}
                if python:
                    refs += python_reads(token, lines, repo.tracked, repo.source, keys)
                elif shell:
                    refs += shell_python(repo, token, lines, keys)
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
