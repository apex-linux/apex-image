#!/bin/sh
# tuned-ppd will not start on a ppd.conf that fails its checks, and GNOME then offers no power modes.
set -eu
CHECK_NAME=power
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

PPD_AC='power-saver=powersave
balanced=balanced
performance=apex-performance'
PPD_BATTERY='balanced=balanced-battery'
PPD_DEFAULT=balanced
PERFORMANCE_PROFILE=apex-performance

if [ -x "$(rootpath /usr/bin/tuned-ppd)" ] || [ -x "$(rootpath /usr/sbin/tuned-ppd)" ]; then
    pass "tuned-ppd is installed"
else
    fail "tuned-ppd is not installed: nothing reads /etc/tuned/ppd.conf (image/packages/base.txt)"
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not available: /etc/tuned/ppd.conf and the TuneD profiles cannot be checked"
    finish
fi

make_tmpdir
if ! python3 - "$ROOT" "$PPD_AC" "$PPD_BATTERY" "$PPD_DEFAULT" "$PERFORMANCE_PROFILE" \
    >"$TMPD/results" 2>"$TMPD/python.err" <<'PY'; then
import collections
import configparser
import os
import re
import sys

root, ppd_ac, ppd_battery, ppd_default, perf_name = sys.argv[1:6]
PPD_CONF = "/etc/tuned/ppd.conf"
MODES = ("power-saver", "balanced", "performance")
# TuneD's profile directories (consts.CFG_DEF_PROFILE_DIRS); a later one wins.
LOAD_DIRS = ("/usr/lib/tuned/profiles", "/etc/tuned/profiles")


def ok(msg):
    print("ok " + msg)


def bad(msg):
    print("bad " + msg)


def rooted(path):
    return os.path.join(root, path.lstrip("/"))


def mapping(text):
    return dict(line.split("=", 1) for line in text.splitlines() if line.strip())


def known_profiles():
    names = set()
    for d in LOAD_DIRS:
        try:
            entries = os.listdir(rooted(d))
        except OSError:
            continue
        names.update(e for e in entries
                     if os.path.isfile(rooted(os.path.join(d, e, "tuned.conf"))))
    return names


def check_ppd():
    """The checks of tuned/ppd/config.py PPDConfig.load_from_file (tuned 2.27, 2.28), then the
    Apex values. Returns the TuneD profiles the file names, none when tuned-ppd would refuse it."""
    path = rooted(PPD_CONF)
    if not os.path.isfile(path):
        bad("%s is missing: tuned-ppd does not start without it" % PPD_CONF)
        return set()
    cfg = configparser.ConfigParser()
    try:
        cfg.read(path, encoding="utf-8")
    except (configparser.Error, UnicodeDecodeError) as e:
        bad("%s does not parse (%s): tuned-ppd does not start"
            % (PPD_CONF, str(e).splitlines()[0]))
        return set()
    problems = []
    if "profiles" not in cfg:
        bad("%s has no [profiles] section: tuned-ppd does not start" % PPD_CONF)
        return set()
    ac = dict(cfg["profiles"])
    problems += ["no %s mode in [profiles]" % m for m in MODES if m not in ac]
    default = cfg["main"].get("default", "balanced") if "main" in cfg else "balanced"
    if default not in ac:
        problems.append("the default mode '%s' is not in [profiles]" % default)
    try:
        detection = cfg.getboolean("main", "battery_detection", fallback="battery" in cfg)
        cfg.getboolean("main", "sysfs_acpi_monitor", fallback=True)
    except ValueError as e:
        problems.append("a [main] option is not a boolean (%s)" % e)
        detection = False
    if detection and "battery" not in cfg:
        problems.append("battery_detection is on but there is no [battery] section")
        dc = dict(ac)
    else:
        dc = {**ac, **dict(cfg["battery"])} if detection else dict(ac)
    unknown = (set(ac.values()) | set(dc.values())) - known_profiles()
    if unknown:
        problems.append("unknown TuneD profiles: %s" % ", ".join(sorted(unknown)))
    extra_modes = set(dc) - set(ac)
    if extra_modes:
        problems.append("[battery] names modes that [profiles] lacks: %s"
                        % ", ".join(sorted(extra_modes)))
    for what, m in (("on AC", ac), ("on battery", dc)):
        if len(set(m.values())) != len(m):
            problems.append("two modes share a TuneD profile %s: %s" % (what, sorted(m.items())))
    for p in problems:
        bad("%s: %s; tuned-ppd does not start" % (PPD_CONF, p))
    if problems:
        return set()
    ok("%s passes tuned-ppd's own validation" % PPD_CONF)

    want_ac, want_dc = mapping(ppd_ac), mapping(ppd_battery)
    battery = dict(cfg["battery"]) if "battery" in cfg else {}
    for what, have, want in (("[profiles]", ac, want_ac), ("[battery]", battery, want_dc)):
        if have == want:
            ok("%s %s is %s"
               % (PPD_CONF, what, ", ".join("%s=%s" % kv for kv in sorted(want.items()))))
        else:
            bad("%s %s is %s, expected exactly %s"
                % (PPD_CONF, what, sorted(have.items()), sorted(want.items())))
    if default == ppd_default:
        ok("%s default mode is %s" % (PPD_CONF, default))
    else:
        bad("%s default mode is %s, expected %s" % (PPD_CONF, default, ppd_default))
    if detection:
        ok("%s switches profiles on battery (battery_detection)" % PPD_CONF)
    else:
        bad("%s has battery_detection off: [battery] (balanced-battery) is never used" % PPD_CONF)
    return set(ac.values()) | set(dc.values())


# Profiles are loaded and merged as TuneD's profiles/{loader,merger}.py do.
class Unit:
    def __init__(self, name, options):
        options = collections.OrderedDict(options)
        self.type = options.pop("type", name)
        self.enabled = options.pop("enabled", True) in (True, "True", "true", 1, "1")
        self.replace = options.pop("replace", False) in (True, "True", "true", 1, "1")
        drop = options.pop("drop", None)
        self.drop = re.split(r"\b\s*[,;]\s*", drop) if drop is not None else []
        for key in ("priority", "prepend", "devices", "devices_udev_regex", "cpuinfo_regex",
                    "uname_regex", "script_pre", "script_post"):
            options.pop(key, None)
        self.options = options


def locate(name):
    """tuned/profiles/locator.py get_config: the last directory that has the profile."""
    for d in reversed(LOAD_DIRS):
        path = os.path.join(d, os.path.basename(name), "tuned.conf")
        if os.path.isfile(rooted(path)):
            return path
    return None


def load(names, profiles, seen, chain):
    """Appends (name, main options, units) for each profile, includes first. Raises
    ValueError with a reason when TuneD could not load it."""
    for name in names:
        optional = name.startswith("-")
        if optional:
            name = name[1:]
        if not name or "/" in name:
            raise ValueError("invalid profile name '%s' in %s" % (name, " -> ".join(chain)))
        path = locate(name)
        if path is None:
            if optional:
                continue
            raise ValueError("profile '%s' (%s) not found in %s"
                             % (name, " -> ".join(chain + [name]), ", ".join(reversed(LOAD_DIRS))))
        if path in seen:
            continue
        seen.append(path)
        cfg = configparser.ConfigParser(delimiters=("=",), inline_comment_prefixes=("#",),
                                        strict=False, interpolation=None)
        cfg.optionxform = str
        try:
            with open(rooted(path), encoding="utf-8") as f:
                cfg.read_file(f, path)
        except (configparser.Error, UnicodeDecodeError) as e:
            raise ValueError("%s does not parse: %s" % (path, str(e).splitlines()[0]))
        main = dict(cfg["main"]) if cfg.has_section("main") else {}
        units = collections.OrderedDict(
            (s, Unit(s, cfg[s])) for s in cfg.sections() if s != "main")
        include = main.pop("include", None)
        if include is not None:
            if "${" in include:
                raise ValueError("%s includes '%s', which uses TuneD variables this check"
                                 " cannot expand" % (path, include))
            load(re.split(r"\s*[,;]\s*", include.strip()), profiles, seen, chain + [name])
        profiles.append((name, main, units))


def merged(name):
    profiles = []
    load([name], profiles, [], [])
    units = collections.OrderedDict()
    for _, _, new in profiles:
        for uname, unit in new.items():
            if uname == "variables":
                continue
            if unit.replace or uname not in units:
                units[uname] = unit
                continue
            old = units[uname]
            old.type, old.enabled = unit.type, unit.enabled
            for option in unit.drop:
                old.options.pop(option, None)
            old.options.update(unit.options)
    return [p[0] for p in profiles], units


named = check_ppd()
for name in sorted(named):
    try:
        order, _ = merged(name)
        ok("TuneD profile %s loads (%s)" % (name, " + ".join(order)))
    except ValueError as e:
        bad("TuneD profile %s does not load: %s" % (name, e))

try:
    order, units = merged(perf_name)
except ValueError as e:
    bad("%s does not load: %s" % (perf_name, e))
    sys.exit(0)
enabled = [u for u in units.values() if u.enabled]
want = (("cpu", "governor", "performance"),
        ("cpu", "energy_performance_preference", "performance"),
        ("cpu", "boost", "1"),
        ("acpi", "platform_profile", "performance"))
for utype, option, value in want:
    have = [u.options.get(option) for u in enabled if u.type == utype]
    if have and all(v == value for v in have):
        ok("%s sets %s %s=%s" % (perf_name, utype, option, value))
    else:
        bad("%s: %s %s is %s, expected %s" % (perf_name, utype, option,
            ", ".join(str(v) for v in have) or "not set", value))
server = []
for u in enabled:
    if u.type == "vm":
        server.append("a vm unit (%s)" % ", ".join(u.options) if u.options else "a vm unit")
    elif u.type == "sysctl":
        server += ["sysctl %s" % k for k in u.options if k.startswith(("vm.", "net."))]
    elif u.type == "disk" and "readahead" in u.options:
        server.append("disk readahead=%s" % u.options["readahead"])
if server:
    bad("%s carries server tunables: %s" % (perf_name, "; ".join(server)))
else:
    ok("%s has no vm unit, no vm.*/net.* sysctl and no disk readahead (merged: %s)"
       % (perf_name, " + ".join(order)))
PY
    [ -s "$TMPD/python.err" ] || echo "python3 failed without a message" >"$TMPD/python.err"
    while IFS= read -r line; do fail "check error: $line"; done <"$TMPD/python.err"
fi

while IFS= read -r line; do
    case $line in
        'ok '*) pass "${line#ok }" ;;
        'bad '*) fail "${line#bad }" ;;
        *) fail "unexpected output: $line" ;;
    esac
done <"$TMPD/results"

finish
