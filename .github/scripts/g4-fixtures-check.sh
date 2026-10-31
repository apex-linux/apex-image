#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat >&2 <<'EOF'

g4-fixtures-check.sh DIR READER...

Checks G4's fixtures in DIR: each file has a row in DIR/README.md's table and is named by one of
the READER scripts, and no line holds what the cut scrubs (host and user names, machine, boot and
filesystem IDs, IPv4, IPv6 and MAC addresses), an email address or a serial number. Audit
proctitle= hex is decoded and checked too.

  g4-fixtures-check.sh DIR READER...    exit 0 when every fixture passes
EOF
    exit 2
}

(($# >= 2)) || usage
exec python3 - "$@" <<'EOF'
import ipaddress
import os
import re
import sys

fixtures, *readers = sys.argv[1:]
readme = os.path.join(fixtures, "README.md")
try:
    table = open(readme, encoding="utf-8").read()
    texts = [open(r, encoding="utf-8").read() for r in readers]
    files = sorted(f for f in os.listdir(fixtures) if f != "README.md")
except OSError as e:
    sys.exit(f"error: cannot read {e.filename}: {e.strerror}")
problems = []
listed = set(re.findall(r"^\| `([^`]+)` \|", table, re.M))
problems += [f"{fixtures}/{f}: has no row in README.md's table" for f in files if f not in listed]
problems += [f"{readme}: lists {f}, which is not in {fixtures}" for f in sorted(listed - set(files))]
for f in files:
    if not any(re.search(rf"(?<![\w.-]){re.escape(f)}(?![\w.-])", t) for t in texts):
        problems.append(f"{fixtures}/{f}: is read by none of {', '.join(readers)}")

USERS = {"root", "gdm", "gdm-greeter", "@TEST_USER@"}
HOSTS = {"?", "guest", "192.0.2.1"}
IPV4S = {"192.0.2.1", "127.0.0.1", "0.0.0.0"}
IPV6S = {"::", "::1"}
UNIT_SUFFIXES = {"service", "socket", "target", "slice", "scope", "mount", "timer", "path", "device", "swap"}
PROCTITLE = re.compile(r"proctitle=([0-9A-F]+)")
RULES = [
    ("host name", re.compile(r"\bhostname=([^\s']+)"), lambda m: m[1] in HOSTS),
    ("host name", re.compile(r"\bapex-builder\b|\b[\w-]+\.(?:local|lan|home|internal|localdomain)\b"), None),
    ("user name", re.compile(r'(?:acct="|for user |\buser=|\bUSER=|\bLOGNAME=|/home/)([\w@.-]+)'), lambda m: m[1] in USERS),
    ("user name", re.compile(r"\buser ([\w@.-]+)\(uid="), lambda m: m[1] in USERS),
    (
        "machine or boot ID",
        re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{32,}(?![0-9A-Fa-f])"),
        lambda m: set(m[0]) == {"0"} or (len(m[0]) == 64 and m.string[: m.start()].endswith("sha256:")),
    ),
    (
        "filesystem or device UUID",
        re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I),
        lambda m: set(m[0]) <= {"0", "-"},
    ),
    ("IPv4 address", re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])"), lambda m: m[0] in IPV4S),
    ("MAC address", re.compile(r"(?<![\w:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![\w:])"), lambda m: m[0] == "02:00:00:00:00:00"),
    ("IPv6 address", re.compile(r"(?<![\w:])[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(?![\w:])"), None),
    ("email address", re.compile(r"[\w.+-]+@([\w-]+(?:\.[\w-]+)+)"), None),
    ("serial number", re.compile(r"serial[\s_]*(?:number|no)?\s*[:=]|ID_SERIAL|SerialNumber|\bS/N\b", re.I), None),
]


def ipv6_ok(text):
    try:
        ipaddress.IPv6Address(text)
    except ValueError:
        return True
    return text in IPV6S


def email_ok(m):
    domain = m[1]
    return domain.rsplit(".", 1)[-1] in UNIT_SUFFIXES or domain == "openssh.com"


def scrub(where, text):
    for name, pattern, ok in RULES:
        for m in pattern.finditer(text):
            if name == "IPv6 address":
                if ipv6_ok(m[0]):
                    continue
            elif name == "email address":
                if email_ok(m):
                    continue
            elif ok and ok(m):
                continue
            problems.append(f"{where}: {name}: {m[0]!r}")


for f in files:
    path = os.path.join(fixtures, f)
    for number, line in enumerate(open(path, encoding="utf-8", errors="replace").read().splitlines(), 1):
        where = f"{path}:{number}"
        if len(line) > 300:
            problems.append(f"{where}: longer than the cut's 300 characters ({len(line)})")
        host = re.match(r"\[\s*[\d.]+\]\s+(\S+)", line) if f.endswith(".manager") else None
        if host and host[1] != "guest":
            problems.append(f"{where}: host name: {host[1]!r}")
        for m in PROCTITLE.finditer(line):
            try:
                scrub(f"{where} (proctitle)", bytes.fromhex(m[1]).replace(b"\0", b" ").decode("utf-8", "replace"))
            except ValueError:
                problems.append(f"{where}: proctitle is not hex: {m[1]!r}")
        scrub(where, PROCTITLE.sub("proctitle=", line))
for p in problems:
    print(f"error: g4 fixtures: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
