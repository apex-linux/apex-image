#!/usr/bin/python3
"""Moves the image's /var into tmpfiles.d, so first boot labels it.

The installer copies an image's /var to the installed system without SELinux
labels, and directories a package expects but the image build removed are
created later by whichever daemon first needs them, with its parent's label:
/var/log/tuned ended up var_log_t and tuned-ppd could not write its log.
systemd-tmpfiles labels what it creates. This writes a tmpfiles.d file with
every path under /var that a package owns or the build left behind, except
those tmpfiles.d already declares, then empties /var. Directories and links
become d and L lines; files are kept under /usr/share/factory and copied by
C lines.

Usage: var_tmpfiles.py <name>, which names /usr/lib/tmpfiles.d/<name>.conf.
"""

import grp
import os
import pathlib
import pwd
import shutil
import stat
import subprocess
import sys

VAR = pathlib.Path("/var")
# Links to /run, which tmpfiles.d manages on its own.
LEGACY = ("/var/run/", "/var/lock/")
FACTORY = pathlib.Path("/usr/share/factory")
RPM_QUERY = (
    "[%{FILENAMES}\t%{FILEMODES:octal}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}"
    "\t%{FILELINKTOS}\n]"
)


def declared_paths() -> set[str]:
    """Returns the paths that tmpfiles.d already manages."""
    config = subprocess.run(
        ["systemd-tmpfiles", "--cat-config"],
        check=True, capture_output=True, text=True,
    ).stdout
    paths = set()
    for line in config.splitlines():
        fields = line.split()
        if len(fields) >= 2 and not line.startswith("#"):
            paths.add(fields[1])
    return paths


def rpm_entries() -> dict[str, tuple[int, str, str, str]]:
    """Returns the directories and links that packages own under /var.

    Each maps to its mode, owner, group and link target.
    """
    output = subprocess.run(
        ["rpm", "-qa", "--qf", RPM_QUERY],
        check=True, capture_output=True, text=True,
    ).stdout
    entries = {}
    for line in output.splitlines():
        path, mode, user, group, target = (line.split("\t") + [""] * 5)[:5]
        if not path.startswith("/var/") or path.startswith(LEGACY):
            continue
        mode = int(mode, 8)
        if stat.S_ISDIR(mode) or stat.S_ISLNK(mode):
            entries[path] = (mode, user, group, target)
    return entries


def name_or_id(lookup, number: int) -> str:
    """Returns the user or group name for an id, or the id itself."""
    try:
        return lookup(number)[0]
    except KeyError:
        return str(number)


def disk_entry(path: pathlib.Path) -> tuple[int, str, str, str]:
    """Returns the mode, owner, group and link target of a path on disk."""
    info = path.lstat()
    target = os.readlink(path) if path.is_symlink() else ""
    return (
        info.st_mode,
        name_or_id(pwd.getpwuid, info.st_uid),
        name_or_id(grp.getgrgid, info.st_gid),
        target,
    )


def tmpfiles_line(path: str, entry: tuple[int, str, str, str]) -> str:
    """Returns the tmpfiles.d line that recreates one path."""
    mode, user, group, target = entry
    perms = f"{stat.S_IMODE(mode):04o}"
    if stat.S_ISLNK(mode):
        return f"L {path} - - - - {target}"
    if stat.S_ISDIR(mode):
        return f"d {path} {perms} {user} {group} - -"
    copy = FACTORY / path.lstrip("/")
    copy.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, copy)
    return f"C {path} {perms} {user} {group} - {copy}"


def main() -> None:
    conf = pathlib.Path("/usr/lib/tmpfiles.d") / f"{sys.argv[1]}.conf"
    declared = declared_paths()
    entries = rpm_entries()
    for path in VAR.rglob("*"):
        entries[str(path)] = disk_entry(path)

    lines = [
        tmpfiles_line(path, entry)
        for path, entry in sorted(entries.items())
        if path not in declared
    ]
    conf.write_text(
        "# Made from the image's /var by image/system/var_tmpfiles.py.\n"
        + "\n".join(lines) + "\n"
    )
    for child in VAR.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()
    print(f"var_tmpfiles: {len(lines)} paths moved from /var to {conf}")


if __name__ == "__main__":
    main()
