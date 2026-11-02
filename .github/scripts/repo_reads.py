# SPDX-License-Identifier: GPL-3.0-or-later
"""The repository files a shell script sources, runs or reads, for vm-paths-check.sh and g4-harness-check.sh."""

import ast
import hashlib
import os
import posixpath
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
            if isinstance(node, ast.Call) and self.qual(node.func) in LOADS and node.args:
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
        called, arg = self.qual(node.func), node.args[0]
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
    first = next((line.strip() for line in lines if line.strip()), "")
    try:
        tree = ast.parse(source_of(path) if run == "file" else "\n".join(lines), path)
        reads = list(Python(path, lines, tracked, source_of, run, seen).reads(tree))
    except (SyntaxError, ValueError) as e:
        why = f"{where} does not parse on Python {sys.version.split()[0]} ({getattr(e, 'msg', e)})"
        reads = [(getattr(e, "lineno", None) or 1, UNPARSED + line_key("__syntax__", first, seen) + UNPARSED + why)]
    except RecursionError:
        reads = [(1, UNPARSED + line_key("__syntax__", first, seen) + UNPARSED + f"{where} nests too deeply for the walk")]
    return list(dict.fromkeys((number + offset, token) for number, token in reads))


class Word:
    def __init__(self, line):
        self.chars, self.line, self.quoted, self.dynamic, self.parts = [], line, False, False, 0
        self.name = None

    @property
    def value(self):
        return "".join(self.chars)


SEPARATORS = set(";&|()\n")
BLANKS, COMMENT = re.compile(r"[ \t]+"), re.compile(r"[^\n]*")
SINGLE, DOUBLE, PLAIN = re.compile(r"[^']*"), re.compile(r'[^"\\$`]+'), re.compile(r"[^\s;&|()<>\\'\"$`]+")
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "case", "esac", "{", "}", "!", "time"}
PREFIXES = {"exec", "command", "builtin", "nohup", "env", "nice", "timeout", "sudo", "as_root"}


class Shell:
    """Commands of a shell script: words with quotes removed, heredocs and here-strings, $( ) inside."""

    def __init__(self, source):
        self.s, self.p, self.line, self.commands = source, 0, 1, []

    def peek(self, n=0):
        return self.s[self.p + n] if self.p + n < len(self.s) else ""

    def take(self):
        c = self.peek()
        self.p += 1
        self.line += c == "\n"
        return c

    def run(self, pattern):
        """The text PATTERN matches here, taken whole."""
        m = pattern.match(self.s, self.p)
        if not m or not m.group():
            return ""
        self.p = m.end()
        self.line += m.group().count("\n")
        return m.group()

    def parse(self, until=None):
        """Commands up to UNTIL (")" or "`" ending a substitution), or the end."""
        command, heredocs, depth = None, [], 0

        def finish():
            nonlocal command
            if command and command["words"]:
                self.commands.append(command)
            command = None

        def new():
            nonlocal command
            if command is None:
                command = {"words": [], "heredocs": [], "herestring": None}
            return command

        while self.p < len(self.s):
            c = self.peek()
            if until and c == until and depth == 0:
                self.take()
                break
            if c == "\\" and self.peek(1) == "\n":
                self.take(), self.take()
            elif c in " \t":
                self.run(BLANKS)
            elif c == "#":
                self.run(COMMENT)
            elif c == "\n":
                self.take()
                finish()
                for heredoc in heredocs:
                    self.heredoc_body(heredoc)
                heredocs = []
            elif c in SEPARATORS:
                self.take()
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth = max(0, depth - 1)
                finish()
            elif c in "<>":
                op = self.take()
                while self.peek() in "<>&-":
                    op += self.take()
                while self.peek() in " \t":
                    self.take()
                target = self.word() if self.peek() not in SEPARATORS | {""} else None
                cmd = new()
                if op.startswith("<<<") and target:
                    cmd["herestring"] = target
                elif op.startswith("<<") and target:
                    heredoc = {"delim": target.value, "quoted": target.quoted, "strip": op.endswith("-"), "body": None}
                    cmd["heredocs"].append(heredoc)
                    heredocs.append(heredoc)
            else:
                new()["words"].append(self.word())
        finish()

    def heredoc_body(self, heredoc):
        body, start = [], self.line
        while self.p < len(self.s):
            end = self.s.find("\n", self.p)
            end = len(self.s) if end < 0 else end
            raw = self.s[self.p:end]
            self.p, self.line = min(end + 1, len(self.s)), self.line + (end < len(self.s))
            line = raw.lstrip("\t") if heredoc["strip"] else raw
            if line == heredoc["delim"]:
                break
            body.append(line)
        heredoc["body"], heredoc["line"] = body, start

    def substitution(self, word, until):
        word.dynamic = True
        self.parse(until)

    def word(self):
        word = Word(self.line)
        start = self.p
        while self.p < len(self.s):
            c = self.peek()
            if c in " \t\n" or c in SEPARATORS or c in "<>" and word.chars:
                break
            if c == "\\":
                self.take()
                nxt = self.take()
                if nxt != "\n":
                    word.chars.append(nxt)
            elif c == "'":
                self.take()
                word.quoted = True
                word.chars.append(self.run(SINGLE))
                self.take()
            elif c == '"':
                self.take()
                word.quoted = True
                while self.p < len(self.s) and self.peek() != '"':
                    d = self.peek()
                    if d == "\\" and self.peek(1) in '$`"\\\n':
                        self.take()
                        nxt = self.take()
                        if nxt != "\n":
                            word.chars.append(nxt)
                    elif d == "$" and self.peek(1) == "(":
                        self.take(), self.take()
                        self.substitution(word, ")")
                    elif d == "`":
                        self.take()
                        self.substitution(word, "`")
                    elif d == "$":
                        self.expansion(word)
                    else:
                        word.chars.append(self.run(DOUBLE) or self.take())
                self.take()
            elif c == "$" and self.peek(1) == "(":
                self.take(), self.take()
                self.substitution(word, ")")
            elif c == "`":
                self.take()
                self.substitution(word, "`")
            elif c == "$":
                self.expansion(word)
            else:
                word.chars.append(self.run(PLAIN) or self.take())
        raw = self.s[start:self.p]
        m = re.fullmatch(r"""(["']?)\$\{?(\w+)\}?\1""", raw)
        if m and m[1] != "'":
            word.name = m[2]
        return word

    def expansion(self, word):
        word.dynamic = True
        word.chars.append(self.take())
        if self.peek() == "{":
            while self.p < len(self.s) and self.peek() != "}":
                word.chars.append(self.take())
            word.chars.append(self.take())
        else:
            while re.match(r"\w", self.peek() or " "):
                word.chars.append(self.take())


def shell_commands(source):
    shell = Shell(source)
    shell.parse()
    return shell.commands


ASSIGN = re.compile(r"([A-Za-z_]\w*)=")


def assignments(commands):
    """(NAME, line, value word) for each NAME=... a command makes, readonly and local ones too."""
    for command in commands:
        words = command["words"]
        if words and not words[0].quoted and words[0].value in ("readonly", "local", "declare", "typeset", "export"):
            words = [w for w in words[1:] if not w.value.startswith("-")]
        for word in words:
            m = ASSIGN.match(word.value)
            if not m:
                break
            yield m[1], word.line, word


PYTHON = re.compile(r"(?:\S*/)?python[0-9.]*")


def python_command(words):
    """The words after the python a command runs, past env, timeout and the like, or None."""
    while words and not words[0].quoted and (words[0].value in RESERVED or ASSIGN.match(words[0].value)):
        words = words[1:]
    while words and not words[0].quoted and words[0].value in PREFIXES:
        words = words[1:]
        while words and not words[0].quoted and (words[0].value.startswith("-") or ASSIGN.match(words[0].value)
                                                  or re.fullmatch(r"[0-9.]+[smhd]?", words[0].value)):
            words = words[1:]
    if words and not words[0].quoted and not words[0].dynamic and PYTHON.fullmatch(words[0].value):
        return words[0], words[1:]
    return None


def python_mode(args):
    """How python's ARGS give it code: ("c", word), ("stdin", None), ("info", None) or ("script", None)."""
    i = 0
    while i < len(args):
        word = args[i]
        value = word.value
        if word.quoted or word.dynamic or not value.startswith("-") or value == "-":
            return ("stdin", None) if value == "-" and not word.quoted else ("script", None)
        if value.startswith("--"):
            if value in ("--version", "--help"):
                return "info", None
            i += 1
            continue
        flags = value[1:]
        for j, flag in enumerate(flags):
            if flag == "c":
                rest = flags[j + 1:]
                return ("c", None) if rest else ("c", args[i + 1] if i + 1 < len(args) else None)
            if flag == "m":
                return "script", None
            if flag in "Vh?":
                return "info", None
            if flag in "WXQ":
                i += 0 if flags[j + 1:] else 1
                break
        i += 1
    return None, None


def embedded_python(path, source, sourced):
    """Each piece of Python PATH's SOURCE runs: ("code", run, first line, lines), or ("lost", line) for one
    whose code the walk cannot get. SOURCED(PATH, line) gives the assignments of the scripts PATH sources."""
    commands = shell_commands(source)
    defined = sorted(((line, name, word) for name, line, word in assignments(commands)), key=lambda d: d[0])
    for command in commands:
        found = python_command(command["words"])
        if not found:
            continue
        program, args = found
        mode, code = python_mode(args)
        if mode in ("info", "script"):
            continue
        if mode != "c":
            if command["herestring"]:
                code = command["herestring"]
            elif command["heredocs"]:
                heredoc = command["heredocs"][-1]
                body = heredoc["body"] or []
                if not heredoc["quoted"] and any("$" in b or "`" in b for b in body):
                    yield "lost", program.line
                else:
                    yield "code", "stdin", heredoc["line"], body
                continue
        if code is None:
            yield "lost", program.line
            continue
        start = None
        if code.name and code.dynamic:
            # A function runs after the whole script is read, so a later global is in sight too.
            before = [d for d in defined if d[1] == code.name and d[0] < program.line]
            after = [d for d in defined if d[1] == code.name and d[0] >= program.line]
            if before or after:
                code = (before[-1] if before else after[0])[2]
            else:
                outside = [w for name, w in sourced(path, program.line) if name == code.name]
                code, start = (outside[-1], program.line) if outside else (None, None)
            if code is None:
                yield "lost", program.line
                continue
            value = ASSIGN.sub("", code.value, count=1)
        else:
            value = code.value
        if code.dynamic:
            yield "lost", program.line
            continue
        yield "code", "c" if mode == "c" else "stdin", start or code.line, value.split("\n")


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


def sourced_assignments(repo, path, seen=None):
    """(NAME, word) for each assignment in the scripts PATH sources, theirs before PATH's own."""
    seen = set() if seen is None else seen
    if path in seen or path not in repo.tracked:
        return []
    seen.add(path)
    source = repo.source(path).decode("utf-8", "replace")
    lines, found = LINES.split(source), []
    commands = shell_commands(source)
    for command in commands:
        words = command["words"]
        if words and not words[0].quoted and words[0].value in (".", "source"):
            for _, ref in references(path, [(words[0].line, lines[words[0].line - 1])]):
                if ref in repo.tracked:
                    found += sourced_assignments(repo, ref, seen)
                    found += [(name, word) for name, _, word in assignments(shell_commands(repo.source(ref).decode("utf-8", "replace")))]
    return found


def shell_python(repo, path, lines, keys):
    """What the Python a shell script runs reads, and a use for each piece whose code the walk cannot get."""
    reads = []
    if not re.search(r"\bpython", "\n".join(lines)):
        return reads
    sourced = lambda script, _line: sourced_assignments(repo, script)  # noqa: E731
    for piece in embedded_python(path, "\n".join(lines), sourced):
        if piece[0] == "lost":
            said = lines[piece[1] - 1].strip()
            reads.append((piece[1], UNRESOLVED + line_key("__python__", said, keys) + UNRESOLVED + said))
        else:
            _, run, start, code = piece
            reads += python_reads(path, code, repo.tracked, repo.source, keys, run=run, offset=start - 1)
    return reads


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
